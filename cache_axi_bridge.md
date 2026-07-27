# cache_axi_bridge — Cache-AXI 转接桥 详细设计文档

## 1. 概述

`cache_axi_bridge` 位于 ICache/DCache 与 AXI3 总线之间，负责：

- 将 Cache 的读/写请求转换为 AXI3 协议
- 仲裁 ICache 与 DCache 对 AXI 读地址通道 (AR) 的竞争
- 检测读-写地址冲突，保证数据一致性
- 追踪已发出但未完成的写事务
- 将 DCache 128bit Burst 写拆分为 4 拍 32bit 发送

**本模块无状态机**，所有控制通过寄存器 + 组合逻辑完成。

---

## 2. 寄存器 / Buffer 清单

本模块共 **5 组存储结构**：

| 编号 | 名称 | 位宽 | 深度 | 用途 |
|------|------|------|------|------|
| B1 | `ic_rd_buf_*` | 35bit | 1 项 | ICache 读请求暂存 |
| B2 | `dc_rd_buf_*` | 35bit | 1 项 | DCache 读请求暂存 |
| B3 | `dc_wr_buf_*` | 167bit | 1 项 | DCache 写请求暂存（含 128bit 数据） |
| R1 | `wr_aw_done_r` / `wr_w_done_r` / `wr_beat` | 5bit | 1 组 | 写握手分拆寄存器 |
| F1 | `wr_pend_*` | 38bit×4 | 4 项 | 写追踪 FIFO |

### 2.1 ICache 读 Buffer (B1)

```verilog
reg         ic_rd_buf_valid;     // 1: Buffer 中有待发送的读请求
reg  [ 2:0] ic_rd_buf_type;      // 3'b000=byte, 3'b001=half, 3'b010=word, 3'b100=4-word burst
reg  [31:0] ic_rd_buf_addr;      // 读地址
```

- **填入条件**：`icache_rd_req && icache_rd_rdy`（Cache 侧握手）
- **清除条件**：`ic_rd_buf_valid && arready && ic_rd_buf_win`（AR 握手 + ICache 赢得仲裁）
- **反压信号**：`icache_rd_rdy = !ic_rd_buf_valid`

### 2.2 DCache 读 Buffer (B2)

```verilog
reg         dc_rd_buf_valid;
reg  [ 2:0] dc_rd_buf_type;
reg  [31:0] dc_rd_buf_addr;
```

- **填入条件**：`dcache_rd_req && dcache_rd_rdy`
- **清除条件**：`dc_rd_buf_valid && arready && dc_rd_buf_win`
- **反压信号**：`dcache_rd_rdy = !dc_rd_buf_valid`

### 2.3 DCache 写 Buffer (B3)

```verilog
reg         dc_wr_buf_valid;
reg  [ 2:0] dc_wr_buf_type;      // 写类型（决定 awsize）
reg  [31:0] dc_wr_buf_addr;
reg  [ 3:0] dc_wr_buf_wstrb;     // 字节选通（直通到 wstrb）
reg  [127:0] dc_wr_buf_data;     // 128bit 写数据（Burst 时按 32bit 切片发送）
```

- **填入条件**：`dcache_wr_req && dcache_wr_rdy`
- **清除条件**：`aw_done && w_done`（AW + W 都完成）
- **反压信号**：`dcache_wr_rdy = !dc_wr_buf_valid && !wr_pend_full`
  - Buffer 满 **或** 写追踪 FIFO 满时拒绝新写

### 2.4 写握手寄存器 (R1)

```verilog
reg         wr_aw_done_r;        // AW 握手已完成标志
reg         wr_w_done_r;         // W  已完成标志（单拍=第一拍 / Burst=最后一拍）
reg  [ 1:0] wr_beat;             // W Burst beat 计数 (0~3)
```

这组寄存器用于**解耦 AW 和 W 通道的握手时序**。AXI 协议中 AW 和 W 可以不同拍完成：

- **`wr_aw_done_r`**：AW 握手完成后置 1，防止重复发 `awvalid`
- **`wr_w_done_r`**：W 最后一拍完成后置 1，防止多发
- **`wr_beat`**：Burst 写时 0→1→2→3，用于从 128bit 中选取当前拍的 32bit 数据

### 2.5 写追踪 FIFO (F1)

```verilog
reg  [31:0] wr_pend_addr  [0:3];  // 4 项，记录已发未回的写地址
reg  [ 5:0] wr_pend_bytes [0:3];  // 4 项，记录每笔写的字节数 (1/2/4/16)
reg  [ 1:0] wr_pend_wptr;         // 写指针
reg  [ 1:0] wr_pend_rptr;         // 读指针
reg  [ 2:0] wr_pend_cnt;          // 有效项数 (0~4)
```

- **深度**：4 项（最多 4 笔未完成的写事务）
- **入队 (push)**：写完成（`aw_done && w_done`），记录地址 + 字节数
- **出队 (pop)**：B 通道握手（`bvalid && bready`）
- **满 / 空**：`wr_pend_full = (cnt==4)`, `wr_pend_empty = (cnt==0)`
- **读写指针**：`((k - rptr) & 2'd3) < cnt` 判断槽位 k 是否有效

#### Push/Pop 状态机

| {push, pop} | 动作 |
|-------------|------|
| 2'b10 | 仅入队：写指针+1，cnt+1 |
| 2'b01 | 仅出队：读指针+1，cnt-1 |
| 2'b11 | 同时入队出队：两个指针都+1，cnt 不变 |
| 2'b00 | 无操作 |

---

## 3. 读路径

### 3.1 仲裁机制

DCache 读优先级 **高于** ICache 读（load 比取指更紧急）：

```verilog
// 自由仲裁（ar_pending=0 时）
dc_rd_buf_win = dc_rd_buf_valid && !dc_rd_buf_conflict;
ic_rd_buf_win = ic_rd_buf_valid && !ic_rd_buf_conflict && !dc_rd_buf_win;
//                                                  ↑ ICache 赢的前提是 DCache 不赢
```

### 3.2 ar_pending 锁

**作用**：防止 `arvalid` 拉高后，AR 通道数据被其他请求中途夺走（违反 AXI 协议）。

```verilog
reg ar_pending;        // AR 通道正在使用中
reg ar_winner_is_dc;   // 当前占用者是 DCache (1) 还是 ICache (0)
```

**状态转移**：

```
       ┌────────── arvalid && arready ──────────┐
       │  (握手完成 → 释放)                       │
       ▼                                         │
  ar_pending=0 ──→ arvalid && !ar_pending ──→ ar_pending=1
       ▲               (新事务 → 锁住)              │
       │                                         │
       └─────────────────────────────────────────┘
```

**锁定后的仲裁**：

```verilog
dc_rd_buf_win = ar_pending ? ar_winner_is_dc         // 锁住：用寄存器值
                           : (dc_rd_buf_valid && !dc_rd_buf_conflict);  // 自由仲裁
ic_rd_buf_win = ar_pending ? !ar_winner_is_dc        // 锁住
                           : (ic_rd_buf_valid && !ic_rd_buf_conflict && !dc_rd_buf_win);
```

### 3.3 关键时序：ar_pending 怎样防止"变脸"

**Bug 场景（修复前）**：

```
Cycle 1: ICache Buffer 有效, arready=0
  → arvalid=1, arid=0 (ICache)

Cycle 2: arready=1, DCache 请求同时到达
  → 组合逻辑立即切换: arid 0→1
  → arvalid 从未拉低但数据变了 → AXI 协议违规！
  → Crossbar 内部寄存器采样到的 arid 不确定 (0 或过渡态)
```

**修复后**：

```
Cycle 1: ICache Buffer 有效, arready=0, ar_pending=0
  → ic_rd_buf_win=1, arvalid=1, arid=0
  → arvalid && !ar_pending → ar_pending<=1, ar_winner_is_dc<=0

Cycle 2: arready=1, DCache 请求同时到达
  → ar_pending=1 → dc_rd_buf_win 被锁为 0
  → arid 保持 0 ← 数据稳定！
  → arvalid && arready → ar_pending<=0

Cycle 3: ar_pending=0, DCache Buffer 有效
  → dc_rd_buf_win=1, arvalid=1, arid=1 ← 新事务，合法
```

### 3.4 AR 通道输出

```verilog
assign arvalid = dc_rd_buf_win || ic_rd_buf_win;
assign arid    = dc_rd_buf_win ? 4'd1 : 4'd0;
assign araddr  = dc_rd_buf_win ? dc_rd_buf_addr : ic_rd_buf_addr;
assign arsize  = 3'b010;   // 固定 4 字节
assign arlen   = dc_rd_buf_win ? (burst ? 8'h03 : 8'h00)
                               : (burst ? 8'h03 : 8'h00);
//              arlen=0: 单拍 (4B), arlen=3: 4拍 Burst (16B)
```

ARID 编码：

| 请求来源 | arid | 含义 |
|----------|------|------|
| DCache | `4'd1` | DCache 读 |
| ICache | `4'd0` | ICache 读 |

### 3.5 读响应分发 (R 通道)

```verilog
assign rready = 1'b1;  // 永远就绪

assign icache_return_valid = rvalid && (rid == 4'd0);
assign dcache_return_valid = rvalid && (rid == 4'd1);
```

R 通道数据直通，按 `rid` 分发到对应 Cache。无 FIFO 缓冲。

**依赖前提**：下游（Crossbar → RAM/confreg）必须正确透传 RID。若下游不可靠，需要额外顺序追踪机制。

### 3.6 读 Buffer 生命周期完整时序

```
正常流程（无冲突、无竞争）：
─────────────────────────────────────────────────────────────────────
Cycle    Cache侧           Bridge内部              AXI AR侧
─────────────────────────────────────────────────────────────────────
  1    rd_req=1         → buffer填入
       rd_rdy=0         valid=1, addr锁存
       
  2    rd_req=0         win=1                   arvalid=1, arid=X
       rd_rdy=0         ar_pending<=1           等待arready
       
  3    rd_req=0         arready握手              → arready=1
       rd_rdy=0         buffer清空               arvalid将变0
                         ar_pending<=0
       
  4    rd_req=0         buffer空                 arvalid=0
       rd_rdy=1         可接受新请求
─────────────────────────────────────────────────────────────────────
```

---

## 4. 写-读冲突检测

### 4.1 检测函数

```verilog
function rd_wr_conflict(rd_addr, rd_bytes);
    // rd_end = rd_addr + rd_bytes - 1
    // 遍历写追踪 FIFO 有效项:  若地址范围重叠 → conflict=1
    // 检查 Write Buffer:      若地址范围重叠 → conflict=1
endfunction
```

### 4.2 检测范围

| 检测对象 | 含义 |
|----------|------|
| 写追踪 FIFO (4项) | 已发到 AXI 总线但 B 响应未回的写 |
| DCache 写 Buffer | 已在 Buffer 中但尚未发到 AXI 总线的写 |

### 4.3 冲突判定逻辑

两段地址 `[A_start, A_end]` 与 `[B_start, B_end]` 冲突 ⇔ **NOT** (`A_end < B_start` **OR** `A_start > B_end`)

即：只要有交集就算冲突。

### 4.4 冲突后的行为

冲突检测结果通过 `ic_rd_buf_conflict` / `dc_rd_buf_conflict` 参与仲裁：

```verilog
dc_rd_buf_win = dc_rd_buf_valid && !dc_rd_buf_conflict;   // 冲突时不能赢
ic_rd_buf_win = ic_rd_buf_valid && !ic_rd_buf_conflict && !dc_rd_buf_win;
```

冲突时该读请求**被阻塞在 Buffer 中**，`arvalid` 不拉高，直到写事务完成（B 响应返回，FIFO 出队）。

---

## 5. 写路径

### 5.1 双通道解耦握手

AXI 写操作需要 AW + W 两个通道都完成。两通道可能不同拍完成，因此引入握手寄存器：

```
aw_done = (Buffer有效 && awready && FIFO未满) || wr_aw_done_r
w_done  = (Buffer有效 && wready && FIFO未满 && 是最后一拍) || wr_w_done_r
```

- `aw_done`：AW 已握手（可能发生在当前拍，也可能之前就寄存了）
- `w_done`：W 已完成（同理）
- **两者都 true → 这笔写事务才算完成**

### 5.2 握手寄存器时序

```
wr_aw_done_r:
  置1: dc_wr_buf_valid && awready && !wr_pend_full && !wr_aw_done_r
  清0: aw_done && w_done  (写事务整体完成)

wr_w_done_r:
  置1: dc_wr_buf_valid && wready && !wr_pend_full && 最后一拍 && !wr_w_done_r
  清0: aw_done && w_done
```

### 5.3 单拍写 vs Burst 写

| | 单拍写 (type≠3'b100) | Burst 写 (type=3'b100) |
|---|---|---|
| awlen | `8'h00` | `8'h03` |
| awsize | `dc_wr_buf_type` | `3'b010` |
| wdata 来源 | `dc_wr_buf_data[31:0]` | `dc_wr_buf_data[wr_beat*32 +: 32]` |
| wlast | 恒为 1 | `wr_beat == 2'd3` |
| 写完成条件 | `aw_done && w_done` (single_wr_done) | `aw_done && w_done && is_burst` |

### 5.4 W 通道 Burst 数据拆分

128bit → 4×32bit，通过 `wr_beat` 计数切片：

```
wr_beat=0: wdata = dc_wr_buf_data[31:0]
wr_beat=1: wdata = dc_wr_buf_data[63:32]
wr_beat=2: wdata = dc_wr_buf_data[95:64]
wr_beat=3: wdata = dc_wr_buf_data[127:96]  → wlast=1
```

wr_beat 递增条件：`wvalid && wready && is_burst && beat != 3`
wr_beat 清零条件：`aw_done && w_done`（写事务完成）

### 5.5 AW/W 通道输出

```verilog
assign awid    = 4'd1;    // 固定 ID
assign awvalid = dc_wr_buf_valid && !wr_aw_done_r && !wr_pend_full;
assign wid     = 4'd1;
assign wvalid  = dc_wr_buf_valid && !wr_pend_full && (is_burst || !wr_w_done_r);
```

关键约束：
- `awvalid`：Buffer 有效 + AW 还没握手 + FIFO 未满
- `wvalid`：Buffer 有效 + FIFO 未满 + （Burst 写 或 单拍写还没完成）
- 对于单拍写：`!wr_w_done_r` 保证只发一拍

### 5.6 写响应 (B 通道)

```verilog
assign bready = !wr_pend_empty;            // FIFO 非空时才接收 B 响应
assign dcache_wr_done = bvalid && bready;  // 写完成通知 DCache
```

### 5.7 写 Buffer 满检查

```verilog
assign dcache_wr_rdy = !dc_wr_buf_valid && !wr_pend_full;
```

两条件：
1. Buffer 空（上一笔已发出）
2. 写追踪 FIFO 未满（≤3 笔未完成）

---

## 6. AXI 常量信号

| 信号 | 值 | 说明 |
|------|-----|------|
| `arburst` | `2'b01` | INCR（递增 burst） |
| `arlock` | `2'b00` | 正常访问 |
| `arcache` | `4'h0` | 非缓存 |
| `arprot` | `3'h0` | 默认保护 |
| `awburst` | `2'b01` | INCR |
| `awlock` | `2'b00` | 正常访问 |
| `awcache` | `4'h0` | 非缓存 |
| `awprot` | `3'h0` | 默认保护 |
| `arsize` | `3'b010` | 4 字节 |
| `awsize` (Burst) | `3'b010` | 4 字节 |
| `awsize` (单拍) | `dc_wr_buf_type` | 1/2/4 字节 |

---

## 7. Cache 侧握手总结

| 信号 | 条件 |
|------|------|
| `icache_rd_rdy` | `!ic_rd_buf_valid` |
| `dcache_rd_rdy` | `!dc_rd_buf_valid` |
| `dcache_wr_rdy` | `!dc_wr_buf_valid && !wr_pend_full` |
| `icache_return_valid` | `rvalid && (rid == 4'd0)` |
| `dcache_return_valid` | `rvalid && (rid == 4'd1)` |
| `dcache_wr_done` | `bvalid && bready` |

---

## 8. 设计约束与依赖

1. **RID 透传依赖**：读响应按 `rid` 区分 ICache/DCache。下游（Crossbar、RAM、confreg）必须保持 RID = ARID。若下游不可靠，可在桥中加顺序追踪绕过 RID。

2. **AR 通道协议合规**：`ar_pending` 锁保证 `arvalid` 拉高后 AR 数据稳定直到握手。

3. **写顺序**：写追踪 FIFO 保证写地址范围记录在案，读请求会检查冲突。FIFO 最多 4 项，超出后反压 `dcache_wr_rdy`。

4. **Burst 限制**：只支持 4-beat INCR burst（16B cache line）。不支持 WRAP/FIXED。

5. **无超时/错误处理**：不检查 `rresp`/`bresp`（假设无 AXI error）。

---

## 9. 关键信号时序图

### 9.1 正常 DCache 读（无竞争）

```
         ____      ____      ____      ____
clk    _/    \____/    \____/    \____/    \____

dc_rd_buf_valid  ___/‾‾‾‾‾‾‾‾‾‾‾‾\__________________
ar_pending       _______/‾‾‾‾‾‾‾\__________________
arvalid          _______/‾‾‾‾‾‾‾‾‾‾‾\______________
arready          _____________/‾‾‾‾\_______________
arid             _______1‾‾‾‾‾‾‾‾‾‾‾\______________
                [Cache填入]  [AR握手]  [buffer清空]
```

### 9.2 ICache 被 DCache 夺走（修复后的行为）

```
         ____      ____      ____      ____
clk    _/    \____/    \____/    \____/    \____

ic_rd_buf_valid  ___/‾‾‾‾‾‾‾‾‾‾‾‾‾\__________________
dc_rd_buf_valid  ___________/‾‾‾‾‾‾‾‾‾\_____________
ar_pending       _______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾\___________
arvalid          _______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\______
arready          _________________/‾‾‾‾\___________
arid             _______0‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__1‾‾‾‾\__
                [ICache占AR]  [arready] [DCache拿到AR]
                              [DCache请求到达但被锁住]
                              [握手用ICache数据完成]
```

### 9.3 Burst 写（4 拍）

```
         ____      ____      ____      ____      ____      ____
clk    _/    \____/    \____/    \____/    \____/    \____/    \____

awvalid ________/‾‾‾\____________________________________
awready ________/‾‾‾\____________________________________
wvalid  ________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\______________
wready  ________/‾‾‾\__/‾‾‾\__/‾‾‾\__/‾‾‾\_____________
wdata   ________D0‾‾\__D1‾‾\__D2‾‾\__D3‾‾\_____________
wlast   _______________________________/‾‾‾\_____________
wr_beat ________0‾‾‾‾‾‾‾‾1‾‾‾‾‾‾‾‾2‾‾‾‾‾‾‾‾3‾‾\________
aw_done ___________________________/‾‾‾‾‾‾‾‾‾‾‾\_______
w_done  _____________________________________/‾‾‾‾‾‾\_
                [AW握手]  [beat0] [beat1] [beat2] [beat3]
                                              [aw_done && w_done → Buffer清空]
```

---

## 10. Type 编码表

| type[2:0] | 含义 | 读字节数 | 写字节数 | arlen/awlen |
|-----------|------|----------|----------|-------------|
| `3'b000` | byte | 1B | 1B | `8'h00` |
| `3'b001` | half | 2B | 2B | `8'h00` |
| `3'b010` | word | 4B | 4B | `8'h00` |
| `3'b100` | 4-word burst | 16B | 16B | `8'h03` |

---

## 11. AXI3 协议规则与本桥实现对照

### 11.1 通道握手规则（VALID/READY）

**规则**：所有 5 个 AXI 通道（AR、R、AW、W、B）均使用 VALID/READY 握手：

> 源端拉高 VALID 后，必须保持 VALID 和所有 Payload 信号稳定，直到目端拉高 READY 完成握手。握手完成（VALID && READY 同一拍为高）后，源端才能在下一拍改变信号。

```
握手前: VALID=1, READY=0  →  数据必须保持稳定！
握手拍: VALID=1, READY=1  →  数据被采样，本事务在源端结束
握手后: 源端可拉低 VALID，或立即开始下一笔事务
```

**本桥实现**：

| 通道 | 桥是源端还是目端 | 如何保证合规 |
|------|-------------------|-------------|
| AR | 源端 | `ar_pending` 锁保证 VALID 拉高后 `arid`/`araddr`/`arlen` 不变 |
| AW | 源端 | `wr_aw_done_r` 防止 AW 握手后重复发 `awvalid` |
| W | 源端 | `wr_w_done_r` + `wr_beat` 保证 Burst 拍数正确、最后一拍 `wlast=1` |
| R | 目端 | `rready=1` 恒定就绪，不反压读数据 |
| B | 目端 | `bready = !wr_pend_empty`，有未完成写才接收 B |

### 11.2 VALID 拉高后数据不可变（A3.2.1）

> **AXI3 spec A3.2.1**: "The source must not change any of the VALID, address, control or data signals until the destination has asserted the READY signal and the transaction has occurred."

这是本桥 **`ar_pending` 锁** 直接对应的协议条款。

**违反场景**（修复前）：

```
Cycle 1: arvalid=1, arid=0 (ICache), arready=0
Cycle 2: DCache 请求到达 → 组合逻辑切换: arid 0→1
         ↑ 违规！arvalid 没掉过但 arid 变了
```

**本桥担保**：`arvalid` 拉高后 `ar_pending` 锁住赢家 → 所有 AR Payload 冻结 → 握手完成才释放。

### 11.3 VALID 不能依赖 READY（A3.3.1）

> **AXI3 spec A3.3.1**: "A source must not assert VALID until the address, control or data signals are valid. Once VALID is asserted, it must remain asserted until the handshake occurs."

> VALID 必须是 READY 无关的——源端不能等待 READY 为高才驱动 VALID。

**本桥实现**：所有 VALID 信号独立于对应 READY：

- `arvalid` 由仲裁 + buffer valid 驱动，不依赖 `arready`
- `awvalid` 由 `dc_wr_buf_valid && !wr_aw_done_r` 驱动，不依赖 `awready`
- `wvalid` 由 `dc_wr_buf_valid && !wr_w_done_r` 驱动（单拍），不依赖 `wready`

### 11.4 读事务顺序与 ID（A5）

> **AXI3 spec A5**: 相同 ARID 的读事务必须按序返回（Transaction Ordering）。不同 ARID 的读事务可以任意顺序返回或交织。

**本桥 ID 策略**：

| 请求来源 | ARID | 预期 RID |
|----------|------|----------|
| DCache 读 | `4'd1` | `4'd1` |
| ICache 读 | `4'd0` | `4'd0` |

- 所有 DCache 读使用相同 ID=1 → AXI 保证 DCache 读之间按序返回
- 所有 ICache 读使用相同 ID=0 → AXI 保证 ICache 读之间按序返回
- DCache 与 ICache 使用不同 ID → 数据可以交织返回（RID 做区分）

**当前风险**：若下游（Crossbar/RAM/confreg）不按 AXI ID 规范传 RID，R 通道分发会错乱。

### 11.5 写事务顺序与 ID（A5）

> 相同 AWID 的写事务必须按序完成（B 响应顺序 = 发出顺序）。

**本桥实现**：所有写使用 `awid = 4'd1`，写追踪 FIFO 保证 B 响应按入队顺序出队。

### 11.6 Burst 限制（A3.4）

> **AXI3 支持 1~16 拍的 Burst**。本桥仅支持：
> - `arlen/awlen = 8'h00`：单拍（1 beat, 1~4 字节）
> - `arlen/awlen = 8'h03`：4 拍 Burst（16 字节 Cache Line）

| Burst 类型 | 支持 | 说明 |
|------------|------|------|
| FIXED | 不支持 | 地址不递增 |
| INCR | 支持 | 地址递增，`arburst/awburst = 2'b01` |
| WRAP | 不支持 | 回绕边界 |

### 11.7 写数据在地址之前（A3.2）

> **AXI3 spec A3.2**: W 通道数据可以在 AW 通道握手之前、之后、或同一拍发送。顺序无要求。

**本桥实现**：AW 和 W 同时从 Write Buffer 发出（同拍 `awvalid` 和 `wvalid` 拉高），两通道独立握手：

```
aw_done = (aw 握手成功 本拍) || (aw 握手成功 之前的拍 → wr_aw_done_r)
w_done  = (w  最后一拍本拍) || (w  最后一拍之前的拍 → wr_w_done_r)
```

`wr_aw_done_r` / `wr_w_done_r` 解耦两个通道的时序，适应任何 AW/W 到达顺序。

### 11.8 WLAST 信号（A3.4.1）

> Burst 写时，最后一拍 W 数据必须同时 `wlast=1`。

**本桥实现**：
- 单拍写：`wlast = 1'b1` 恒定
- Burst 写：`wlast = (wr_beat == 2'd3)`，第 4 拍 (beat=3) 时拉高

### 11.9 写响应（B 通道）（A3.5.1）

> 每笔 AXI 写事务必须恰好有一个 B 响应。BVALID 拉高代表该笔写事务已全局可见。

**本桥实现**：
- `bready = !wr_pend_empty`：FIFO 中有未完成的写时接收 B
- `dcache_wr_done = bvalid && bready`：写完成通知 DCache
- 写追踪 FIFO 出队 (pop) 在 B 握手时

### 11.10 地址字节选通（WSTRB）（A3.4.3）

> `wstrb[3:0]` 对应 `wdata[31:0]` 的 4 个字节，每个 bit 指示该字节是否写入。

**本桥实现**：`wstrb` 直接从 DCache 的 `dcache_wr_wstrb` 直通。

### 11.11 桥未实现的 AXI 特性

| 特性 | 状态 | 说明 |
|------|------|------|
| Read/Write interleaving | 不支持 | 同 ID 读写可能冲突，通过写追踪 FIFO 做地址冲突检测 |
| Outstanding transactions | 读: 1 笔深度 | 读 Buffer 单深度 + ar_pending 锁，不支持多笔未完成读 |
| Outstanding transactions | 写: ≤4 笔深度 | 写追踪 FIFO 4 项 |
| AXI4 长 Burst (≤256) | 不支持 | 桥为 AXI3，arlen/awlen 4bit |
| Exclusive access | 不支持 | 无 ARLOCK/AWLOCK exclusive |
| AxCACHE/AxPROT | 固定值 | 直出常量 |
| AxQOS/AxREGION | 不支持 | 未连接 |
| AxUSER | 不支持 | 未连接 |
| RRESP/BRESP 错误 | 忽略 | 不检查 DECERR/SLVERR，假设下游始终 OK |

---

## 12. ar_pending 锁 — 设计原理

### 12.1 为什么需要

AXI 规范 A3.2.1 要求：VALID 拉高后，**所有 Payload（ARID、ARADDR、ARLEN 等）必须保持稳定** 直到握手完成。

本桥的 AR 通道是纯组合逻辑从仲裁输出，没有寄存器。如果仲裁结果在 `arvalid=1` 期间变化（例如 ICache 正等 AR 握手时 DCache 来了新请求），组合逻辑会立即切换信号——违反协议。

### 12.2 解决方案

`ar_pending` 是一个 1-bit 寄存器，**在 arvalid 首次拉高时捕获当前赢家，冻结仲裁直到握手完成**。

```
ar_pending=0 (空闲):
  仲裁 = 自由竞争 (DCache > ICache)
  若 arvalid 拉高 → 下一拍: ar_pending=1, 锁住赢家

ar_pending=1 (锁定):
  仲裁 = 冻结，输出 = ar_winner_is_dc (寄存器值)
  若 arready 握手 → 下一拍: ar_pending=0, 释放
```

### 12.3 状态转移条件

| 当前状态 | 条件 | 下一状态 | 动作 |
|----------|------|----------|------|
| `ar_pending=0` | `arvalid && arready` | → 0 | 单拍事务，直接完成（不留锁） |
| `ar_pending=0` | `arvalid && !arready` | → 1 | 事务未完成，锁住赢家 |
| `ar_pending=1` | `arvalid && arready` | → 0 | 握手完成，释放 |
| `ar_pending=1` | `arvalid && !arready` | → 1 | 继续等待 |

注意 `arvalid && arready` 的优先级高于 `arvalid && !ar_pending`。这保证单拍事务（VALID 和 READY 同拍为高）不会留下悬空的 `ar_pending`。

### 12.4 对性能的影响

`ar_pending` 锁只在 **AR 握手延迟 > 1 拍** 时生效（即 `arready` 晚于 `arvalid` 到来）。如果下游始终能同拍握手（`arready` 一直为 1），则 `ar_pending` 永远不置位，零开销。

对 5 级顺序流水线 CPU，AR 握手延迟罕见，`ar_pending` 的实际性能影响可忽略。

---

## 13. 踩坑记录 — 容易忘记的 AXI 规则

以下是开发本桥过程中**因忘记 AXI 协议规定而导致的 bug**，每条都对应协议中的具体条款。

### 13.1 VALID 拉起后数据不能变 ⚠️ 本次 bug 根因

> **AXI spec A3.2.1**: 源端拉高 VALID 后，**所有 Payload 信号必须保持稳定**，直到 READY 握手完成。

**实际 bug**：ICache 拉高了 `arvalid` 等待 `arready`，此时 DCache 仲裁获胜，组合逻辑立刻把 `arid` 从 0 切换为 1。`arvalid` 从未拉低但数据变了 → AXI 协议违规。

**下游后果**：Crossbar 内部有寄存延迟，它采样到的 `arid` 不是稳定的 1 或 0，而是过渡态/旧值 → `ram_arid` 输出为 0 → R 通道返回 `rid=0` → 桥误认作 ICache 数据。

**修复**：加 `ar_pending` 锁（见第 12 节）。

### 13.2 不禁止当拍返回数据 ⚠️ ar_pending 不能留悬空

> AXI 允许 `VALID` 和 `READY` 同一拍为高（当拍握手/back-to-back）。源端必须在握手拍之后释放资源。

**容易犯的错**：`ar_pending` 在 `arvalid && !ar_pending` 时置 1，但如果 `arready` 也同拍为高，事务已经完成了，`ar_pending` 不应该留到下一拍。

**修复**：`arvalid && arready` 的优先级**高于** `arvalid && !ar_pending`。同拍握手时直接跳过锁。

### 13.3 Burst 读 AR 只需握手一次 ⚠️ 不要在每拍 R 都发 AR

> Burst 读（arlen > 0）只需 **一次 AR 握手**。R 通道自动返回 arlen+1 拍数据，每拍递增地址。不需要为每一拍 R 数据都发一次 AR。

**容易犯的错**：在 R 通道每拍返回时重新发 AR，或者不理解 arlen 的含义。

**本桥实现**：`arlen` 正确编码（0=单拍, 3=4拍），AR 握手完成后 `ar_pending` 释放即可接受下一笔读请求，**不需要等 rlast**。

### 13.4 写地址 (AW) 握手一次，写数据 (W) 握手多次 ⚠️ 不要多发 AW

> Burst 写时，**AW 只握手一次**（awlen 指定总拍数），**W 通道握手 awlen+1 次**，每次 W 握手传输一个 beat。

**容易犯的错**：为每个 W beat 都发一次 AW。

**本桥实现**：`wr_aw_done_r` 在 AW 握手后置 1，阻止 `awvalid` 再次拉高。`awvalid = dc_wr_buf_valid && !wr_aw_done_r && !wr_pend_full`。

### 13.5 AW 和 W 可以分开握手 ⚠️ 不能假定同拍完成

> AW 通道和 W 通道**完全独立握手**。AW 可能在 W 之前、之后、或同一拍完成。源端必须处理三种情况。

**容易犯的错**：假定 AW 和 W 总是同拍完成，用一个同步信号控制两个通道。

**本桥实现**：`aw_done` 和 `w_done` 独立计算，各自有寄存器 `wr_aw_done_r` / `wr_w_done_r`。只有**两者都 done** 才算写事务完成。

| 场景 | AW 时序 | W 时序 | aw_done | w_done | 事务完成？ |
|------|---------|--------|---------|--------|-----------|
| AW 先到 | 第1拍握手 | 第3拍完成 | 第1拍 done | 第3拍 done | 第3拍 ✓ |
| W 先到 | 第3拍握手 | 第1拍完成 | 第3拍 done | 第1拍 done | 第3拍 ✓ |
| 同拍完成 | 第1拍握手 | 第1拍完成 | 第1拍 done | 第1拍 done | 第1拍 ✓ |

### 13.6 总结：5 条规则对照

| # | AXI 规则 | 违反时的症状 | 本桥的保证 |
|---|----------|-------------|-----------|
| 1 | VALID 拉起后数据不能变 | `arid` 半路被夺走，下游采样到 0 | `ar_pending` 锁 |
| 2 | 允许当拍返回 | `ar_pending` 悬空，多拍假 `arvalid` | if-else 优先级 |
| 3 | Burst 读 AR 只握手一次 | 反复发 AR，`arvalid` 逻辑混乱 | `arlen` 编码 + buffer 清空时机 |
| 4 | AW 一次 + W 多次 | 多发了 AW，写地址被覆盖 | `wr_aw_done_r` 阻止 |
| 5 | AW 和 W 可分开握手 | 一方没完成就清除 Buffer | `aw_done` + `w_done` 双重条件 |
