# Project Memory — FPGA Camera Display (OV5640 → EP4CE10F17C8N → AN430 LCD)

User: Kong. Quartus project: CameraCapture (this folder). Quartus Prime 25.1 Lite.

## 状态(2026-07-14)
**主线完成**:摄像头 → DVP → SDRAM乒乓 → LCD 实时显示,YUV422→RGB888 链路,画质已调优,用户确认"画面完美"。
顶层 = `camera_display_top`。各阶段测试顶层保留:dvp_test_top / sdram_test_top / lcd_top / lcd_pattern_top / sd_test_top,切 TOP_LEVEL_ENTITY 即可复用。

**三按钮模式选择**:key1→Sobel边缘检测,key2→阈值二值化,key3→质心+运动追踪(默认)。按键引脚(key1_n/key2_n/key3_n=M15/M16/E16,来自 AX4010 手册 Part13)已加入 qsf。

**Sobel 前加了一级高斯模糊(gaussian_blur3x3.v)**:用户反馈"电脑上Sobel能描出完整人脸轮廓甚至痣,板子上连轮廓都描不完整"——原因是板上只有裸的单阈值 Sobel,没有电脑上 Canny 那一套(高斯模糊去噪+非极大值抑制+双阈值滞后连接),轮廓在光照弱的地方梯度本来就小,单点独立判断导致断线。先加了模糊这一步(3x3核 [1 2 1;2 4 2;1 2 1]/16,架构照抄 sobel_edge.v 已验证正确的同步读+延迟对齐写法),接在 disp_y 和 sobel_edge 之间,sobel_edge 现在吃 blur 模块延迟对齐后的 y8/pixel_x/y/de。仿真验证过(平坦帧不变、阶跃边缘处产生真实的中间过渡值,不是直通)。

**非极大值抑制(NMS)已实现**:用户反馈"EDGE_THRESH调低了之后线条变粗"——原因是真实边缘的梯度幅值是个"小山包"(渐升到峰值再渐降,不是单点尖峰),单纯阈值判断会把山包两侧肩部一起点亮,阈值越低点亮的肩部越宽。修复:`sobel_edge.v` 改造成只算原始梯度,输出 `magnitude`(13位幅值)+ `direction`(2位方向桶:0=水平梯度/竖直边,1=对角"/",2=竖直梯度/水平边,3=对角"\\",用 |Gx| vs 2×|Gy| 的移位比较近似 atan2,不用除法器)+ 延迟对齐的 pixel_x_out/pixel_y_out/de_out,不再直接出 edge_r/g/b。新建 `nms_thresh.v` 接在 sobel_edge 后面:架构照抄 sobel_edge 的同步读行缓冲写法(2行幅值缓冲 mline_a/mline_b + 1行方向缓冲 dline_b——NMS只需要中心像素自己的方向,方向缓冲只需缓冲会成为窗口中心的那一行,不需要像幅值一样缓冲2行),3x3幅值窗口做好后,中心像素沿自己的梯度方向跟对应的两个邻居比较(比如方向=0/水平梯度就比左右邻居),`(m1d1 > nbr_a) && (m1d1 >= nbr_b)` 非对称比较(一边严格大于一边大于等于,专门处理阶跃边缘两个相邻像素幅值算出来正好相等的情况,否则会两个都判定为局部最大导致边缘变2像素宽——这个问题是集成测试时真实碰到并修复的,不是纸上假设),不是局部最大就抑制为0,最后再跟 EDGE_THRESH 比较。camera_display_top.v 里 sobel_edge → nms_thresh → 原来的 sobel_r/g/b 顶层 mux 位置,qsf 加了 nms_thresh.v。三个仿真全过(tb_sobel_edge.v 验证幅值+方向本身;tb_nms_thresh.v 用合成"山包"波形验证抑制效果;tb_integration_nms.v 把真实 sobel_edge+nms_thresh 串联,同一个阶跃边缘分别接低阈值(50)和高阈值(400)两个 nms_thresh 实例,验证两者边缘宽度都稳定在1像素——直接复现并验证修复了用户反馈的那个问题)。**用户还没编译验证效果**,理论上 LE/LAB 增量很小(方向缓冲只有2位宽,幅值缓冲480深×13位,远小于已用的 M9K 容量)。

**LAB 超限问题已定位并修复(待用户编译验证)**:真正原因不是 M9K 推断"被拒绝",而是 `sobel_edge.v` 的 `line_a/line_b` 和 `motion_detector.v` 的 `luma_mem/changed_mem` 用的是组合逻辑读(`wire = arr[idx]`,同一拍内地址给出立刻拿到数据)。M9K 硬件的读端口物理上只支持同步读(这一拍给地址,下一拍数据才出来),组合读这种写法不管加不加 `ramstyle` 属性都不可能映射上 M9K——Quartus 只能老实地用几百个寄存器+一个巨大多路选择器在 LE 里"手搭"一个能瞬间查表的假内存,这正是吃掉几百上千 LE 的元凶。之前那次 ramstyle=M9K 的"修复"编译前后 LAB 数字一模一样(858),现在回头看就是因为它对组合读的场景根本不起作用。

已修复:两个模块的内存读都改成寄存器化同步读,写端口相应延迟一拍对齐(sobel_edge.v 新增 la/lb/px_d1/py_d1/y8_d1/de_d1 延迟链;motion_detector.v 新增 flushing_d1/flush_addr_d1/cur_avg_d1 延迟链),仿真通过(tb_sobel_edge.v 调整了边缘位置容差 [8,12]→[8,13],因为整条流水线多了一拍;tb_motion_detector_v2.v 未改动即通过)。Sobel 已重新在 camera_display_top.v 和 qsf 里启用。**下一步:用户需要重新完整编译一次,确认 LAB 数量是否真的降到 645 以内**——如果还超,说明还有其他大头没找到,需要 Quartus 的 Analysis & Synthesis Resource Usage Summary 逐模块排查,不要再猜。

## 关键架构决定
- 传感器输出 **YUV422(YUYV)**,不是 RGB565:8位亮度消除了 RGB565 的同心圆色带。0x4300=0x30, 0x501f=0x00
- LCD 侧 `yuv422_to_rgb888.v` 做 BT.601 定点转换,1像素延迟
- **LCD 三通道数据总线位序需反转**(板上接线相对 qsf 编号是 MSB-first),已在 camera_display_top 和 lcd_pattern_top 里用 generate 反转。彩条测不出位序错,渐变才能
- PLL(my_pll.v,手写 altpll):c0=100M, c1=24M(XCLK), c2=8.955M(LCD,精确9M与100/24共VCO不可实现,VCO=600M), c3=100M/-75°(=7917ps)给 SDRAM 芯片
- SDRAM(W9825G6KH-6,板载丝印;手册写 HY57V2562GTR,引脚兼容):sdram_ctrl.v 突发4、CL2@100M,bank[0]=乒乓缓冲位,自测双 buffer 全通过
- dvp_capture:数据打拍与 href 对齐;字节序 {第一字节,第二字节}
- 帧缓冲:pixel_fifo(dcfifo 16b×512 show-ahead)×2 + frame_buffer.v 乒乓调度,CDC 用 toggle+同步器

## SD 卡(暂停,等换卡)
- sd_spi.v / sd_ctrl.v / sd_test_top.v / sd_dump.py 已就绪,协议实现达到 FatFs 等级:真CRC、每命令CS翻转+等就绪、轮询间隔、ACMD41→CMD1 降级
- **联想 16GB TF 卡 SPI 模式固件不完整**:只应答 CMD0/CMD8,CMD55/CMD1 全部沉默(判别实验:第二次 CMD8 在同位置正常 → 非引擎问题)。Windows 读卡器正常(走 SD 模式)
- 结论:需换闪迪/金士顿/三星正品 SDHC 8-32GB。现有固件对正常卡应可直接工作
- LED 错误码表在 sd_ctrl.v 注释;SD_DEBUG_REVIEW.md 有完整调试记录
- 用户最终目的:存单帧原始图到卡→PC对比(已用 lcd_pattern_top 的受控图案实验替代完成:屏无罪,色带=565量化)

## 踩坑记录(重要)
- **qsf 常被 Quartus 重写且末行无换行**:追加内容前必须检查,曾两次粘连、一次尾部被灌 31KB 空字节(截断修复)
- F16(sdram_cke)是 nCEO 双功能脚:需 `CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION "USE AS REGULAR IO"`
- E15 是时钟专用输入,不支持 weak pullup assignment
- 全局 IO 标准:`STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"`(默认2.5V会和 LCD 3.3V 冲突;-entity 作用域的 IO assignment 换顶层就失效)
- SignalTap:换顶层前必须 ENABLE_SIGNALTAP OFF,否则旧探点报错;探点用 pre-synthesis 名,别选 ~feeder;存储限定(Input port=字节done)可实现每字节一采样;触发要"先 Run 再按复位"
- SD 卡换卡必须断电插拔(卡内部状态只有断电能清);wmic 已从新 Win11 移除,用 Get-Disk
- ov5640_init 在软复位(0x3008=0x82)后有 10ms 延时状态(必需)
- sccb/sd 的 spi_start 类握手:busy 延迟两拍,发送分支必须 `!busy && !start` 双守卫防连发

## 摄像头画质寄存器(已调)
- AEC 目标:0x3a0f=38/3a10=30/3a1b=38/3a1e=30/3a11=70/3a1f=18
- 饱和度:0x5584=0x40(原0x10导致发灰)
- 0x5000=0xa7(LENC+gamma+BPC/WPC)
- 镜头为手动对焦,画质问题先转镜头

## 引脚(qsf 已全部配置)
摄像头:SIO_C=F1,SIO_D=F3,PCLK=G1,VSYNC=F2,HREF=K1,XCLK=K2,D[7:0]=J2,J1,N5,L1,M1,G2,M6,L2,RESET=N6,PWDN=M7
LCD:R=R10~T14,G=R6~T10,B=P3~T6,DCLK=T2,HS=M9,VS=L10,DE=L9(注意位序反转在RTL做)
SDRAM:CLK=B14,CKE=F16,CS=K10,WE=J13,CAS=J12,RAS=K11,DQM=J14/G15,BA=G11/F13,A0-12=F11,E11,D14,C14,A14,A15,B16,C15,C16,D15,F14,D16,F15,DQ0-15=P14,M12,N14,L12,L13,L14,L11,K12,G16,J11,J16,J15,K16,K15,L16,L15
SD:NCS=D11,CLK=D12,DIN(MOSI)=F10,DOUT(MISO)=E15
LED:E10,F9,C9,D9;CLK=E1;RST=N13(板上共8个LED,本工程只驱动4个,其余悬空微亮属正常)
KEY(按下=0,来自AX4010手册Part13):KEY1=M15,KEY2=M16,KEY3=E16(注:M15 与旧测试信号 key_start 共用,key_start属于已弃用的 sccb_top_test,非当前 TOP_LEVEL_ENTITY,不冲突)

## 后续可选方向
1. 换卡后:拍照模式(冻结一帧510块写SD,sd_dump.py --frame 转PNG)
2. OV5640 JPEG 模式全分辨率静态照(证明500W传感器能力)
3. CMD25 多块连写提升SD吞吐
