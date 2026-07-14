# SD 卡子系统架构评审文档

生成日期:2026-07-08。用于人工检查 SD 卡初始化失败(错误码 0011)问题。

## 一、文件清单与职责

### SD 卡路径(本次评审重点)

**sd_spi.v — SPI 字节收发器(最底层)**
- 职责:一次收发 1 个字节,全双工,MSB 在前,SPI mode 0(CPOL=0, CPHA=0)
- 时钟:输入 50MHz;`speed=0` 时 SCK≈390kHz(初始化阶段),`speed=1` 时 12.5MHz(数据阶段)
- 握手:`start` 脉冲启动 → `busy` 升高 → 16 个半周期完成 8 位 → `done` 脉冲 + `rx_byte` 有效
- 时序细节:MOSI 在下降沿更新、上升沿被卡采样;MISO 在上升沿采样进 rx 移位器
- 字节间时钟停止(SCK 保持低),这是 SPI 允许的

**sd_ctrl.v — SD 卡协议控制器(核心)**
- 职责:上电初始化序列 + CMD24 单块写
- 初始化流程(状态机):
  1. `ST_POWER`:上电等 10ms
  2. `ST_DUMMY`:CS 拉高发 10×0xFF(80 时钟,规范要求≥74)
  3. CMD0(CRC 0x95)→ 期望 R1=0x01,否则 err=1
  4. CMD8 arg=0x1AA(CRC 0x87)→ 期望 R1=0x01 且回显 0x1AA,否则 err=2
  5. CMD55(CRC 0x65)+ ACMD41 arg=0x40000000(CRC 0x77)循环,每轮间隔 1ms,2000 轮(约 3~5 秒)超时
  6. CMD58 读 OCR → 切 12.5MHz → `init_done=1`
- 共享命令引擎:`set_cmd(命令, 参数, CRC, 额外响应字节数, 返回状态)` 装载后走
  `ST_CMD_SYNC → ST_CMD_SEND → ST_CMD_R1 → (ST_CMD_EXTRA) → 返回状态`
  - `ST_CMD_SYNC`(仿 FatFs):CS 拉高发 1 字节(deselect,强制卡解析器重同步)→ CS 拉低发 1 字节 → 继续发 0xFF 直到读回 0xFF(等卡就绪,上限 255 字节)
  - `ST_CMD_R1`:发 0xFF 轮询,收到 bit7=0 的字节即为 R1,存入 `r1`;17 字节内无响应则 r1=0xFF
  - `ST_CMD_EXTRA`:R7/R3 的 4 个尾随字节,移入 `resp32`
- 写块流程:CMD24 → R1=0 → 0xFF 间隔 → 令牌 0xFE → 512 字节(`byte_req` 每字节脉冲一次向上游取数)→ 2 CRC → 数据响应(xxx00101)→ 等忙 → `wr_done`
- 错误码(显示在 LED,LED3=最高位):
  - 0001: CMD0 无响应
  - 0010: CMD8 失败
  - 0011: ACMD41 超时且最后一次响应是 0xFF(卡不回话)
  - 0111: ACMD41 超时且最后响应 0x01(卡停 idle)
  - 0110: 最后响应 0x05(非法命令)
  - 1001: 其他值
  - 0100/0101: 写响应错/写忙超时

**sd_test_top.v — 自测顶层(当前编译顶层)**
- PLL 不使用,直接用 50MHz
- 流程:等 `init_done` → 向块 2048 起连写 8 块,数据= `byte_index[7:0] ^ block[7:0]` → 完成
- LED:正常模式 {心跳, 0, 写完, init};出错时 4 位错误码(心跳停闪即错误码模式)

**sd_dump.py — PC 端工具**
- `--verify`:读块 2048~2055 与图案比对
- `--frame`:读 510 块 RGB565 转 PNG

### 摄像头显示路径(已验证工作,与本问题无关)

- `my_pll.v`:50M→100M/24M/8.955M/100M(-75°)
- `CameraCapture.v`:SCCB(I2C 类)写控制器,16 位寄存器地址
- `ov5640_init.v` + `ov5640_reg_table.v`:上电时序 + 253 条寄存器
- `dvp_capture.v`:DVP 8 位→RGB565 组包(字节对齐已修)
- `sdram_ctrl.v`:W9825G6KH 控制器,突发 4,乒乓 bank(自测通过)
- `pixel_fifo.v` / `frame_buffer.v`:双时钟 FIFO + 乒乓调度
- `lcd_driver.v` / `rgb565_to_rgb888.v`:AN430 时序 + 色深扩展
- `camera_display_top.v`:全系统顶层(位序修正在此)
- `dvp_test_top.v` / `sdram_test_top.v` / `lcd_top.v`:各阶段测试顶层

## 二、症状矩阵(截至目前)

| 事实 | 含义 |
|------|------|
| CMD0 → 0x01(冷启动) | 物理链路、CS、时钟、MOSI/MISO 全部正常 |
| CMD8 → 0x01 + 回显 0x1AA | RX 采样字节对齐精确无误(12 位回显核对) |
| CMD55/ACMD41 循环超时,最后 r1=0xFF | 卡对第 3 条及以后的命令不回话 |
| 暖复位后 CMD0 也无响应(err1) | 卡处于失步/挂起状态,只有断电能恢复 |
| Windows 读卡器读写正常 | 卡本身功能正常 |

## 三、已实施的修复(均未解决)

1. `spi_start`/`byte_req` 双发 bug(busy 延迟两拍导致)→ 已加 `!spi_start` 守卫
2. 每命令前置 0xFF 同步字节
3. CMD55/ACMD41/CMD58 换真实 CRC(0x65/0x77/0xFD,算法经 5 个已知值验证)
4. 仿 FatFs 的每命令 CS 翻转(deselect→select)+ 等就绪(wait_ready)
5. ACMD41 轮询间隔 1ms
6. ACMD41 电压窗口 0x40FF8000(已按要求撤回,当前为 0x40000000)

## 四、剩余假设(按可能性排序)

**H1:命令引擎在"经过 ST_CMD_EXTRA 之后"的首条命令上有位置性 bug**
CMD8 是唯一走过 EXTRA(读 4 尾随字节)的命令,CMD55 是它之后第一条命令。
若 EXTRA 残留了某种状态污染,恰好只打击后续命令。
→ 判别实验:把 CMD55 的位置换成再发一次 CMD8。若第二次 CMD8 也无响应,
则实锤引擎位置性 bug;若有响应,则问题特定于 CMD55/卡。

**H2:该卡对 CMD55 的响应超过 17 字节轮询窗口**
规范 Ncr≤8 字节,但劣质控制器可能更慢。
→ 把轮询窗口从 16 扩到 64 试探。

**H3:卡是贴牌/低质控制器,SPI 模式兼容性差**
联想品牌卡多为 OEM 贴牌,主控来源不一。
→ 换一张不同品牌的卡对照(闪迪/金士顿/三星)。

**H4:信号完整性(仅在持续通信后恶化)**
概率低:390kHz 极慢,且 CMD0/CMD8 每次都过。

## 五、建议的下一步

按 H1 判别实验 → H2 扩窗 → H3 换卡的顺序,每步一次编译。
H1 与 H2 可合并为一次编译(改动互不干扰)。
