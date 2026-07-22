# Project Memory — FPGA Camera Display (OV5640 → EP4CE10F17C8N → AN430 LCD)

User: Kong. Quartus project: CameraCapture (this folder). Quartus Prime 25.1 Lite.

## 状态(2026-07-15)
**主线完成**:摄像头 → DVP → SDRAM乒乓 → LCD 实时显示,YUV422→RGB888 链路,画质已调优,用户确认"画面完美"。
顶层 = `camera_display_top`。各阶段测试顶层保留:dvp_test_top / sdram_test_top / lcd_top / lcd_pattern_top / sd_test_top,切 TOP_LEVEL_ENTITY 即可复用。

**三按钮模式选择**:key1→Sobel边缘检测,key2→EAN-13/UPC-A条码识别(原阈值二值化→Code 39→现EAN-13,已替换两次),key3→质心追踪(默认)。按键引脚(key1_n/key2_n/key3_n=M15/M16/E16,来自 AX4010 手册 Part13)已加入 qsf。

**Sobel 前加了一级高斯模糊(gaussian_blur3x3.v)**:用户反馈"电脑上Sobel能描出完整人脸轮廓甚至痣,板子上连轮廓都描不完整"——原因是板上只有裸的单阈值 Sobel,没有电脑上 Canny 那一套(高斯模糊去噪+非极大值抑制+双阈值滞后连接),轮廓在光照弱的地方梯度本来就小,单点独立判断导致断线。先加了模糊这一步(3x3核 [1 2 1;2 4 2;1 2 1]/16,架构照抄 sobel_edge.v 已验证正确的同步读+延迟对齐写法),接在 disp_y 和 sobel_edge 之间,sobel_edge 现在吃 blur 模块延迟对齐后的 y8/pixel_x/y/de。仿真验证过(平坦帧不变、阶跃边缘处产生真实的中间过渡值,不是直通)。

**非极大值抑制(NMS)已实现**:用户反馈"EDGE_THRESH调低了之后线条变粗"——原因是真实边缘的梯度幅值是个"小山包"(渐升到峰值再渐降,不是单点尖峰),单纯阈值判断会把山包两侧肩部一起点亮,阈值越低点亮的肩部越宽。修复:`sobel_edge.v` 改造成只算原始梯度,输出 `magnitude`(13位幅值)+ `direction`(2位方向桶:0=水平梯度/竖直边,1=对角"/",2=竖直梯度/水平边,3=对角"\\",用 |Gx| vs 2×|Gy| 的移位比较近似 atan2,不用除法器)+ 延迟对齐的 pixel_x_out/pixel_y_out/de_out,不再直接出 edge_r/g/b。新建 `nms_thresh.v` 接在 sobel_edge 后面:架构照抄 sobel_edge 的同步读行缓冲写法(2行幅值缓冲 mline_a/mline_b + 1行方向缓冲 dline_b——NMS只需要中心像素自己的方向,方向缓冲只需缓冲会成为窗口中心的那一行,不需要像幅值一样缓冲2行),3x3幅值窗口做好后,中心像素沿自己的梯度方向跟对应的两个邻居比较(比如方向=0/水平梯度就比左右邻居),`(m1d1 > nbr_a) && (m1d1 >= nbr_b)` 非对称比较(一边严格大于一边大于等于,专门处理阶跃边缘两个相邻像素幅值算出来正好相等的情况,否则会两个都判定为局部最大导致边缘变2像素宽——这个问题是集成测试时真实碰到并修复的,不是纸上假设),不是局部最大就抑制为0,最后再跟 EDGE_THRESH 比较。camera_display_top.v 里 sobel_edge → nms_thresh → 原来的 sobel_r/g/b 顶层 mux 位置,qsf 加了 nms_thresh.v。三个仿真全过(tb_sobel_edge.v 验证幅值+方向本身;tb_nms_thresh.v 用合成"山包"波形验证抑制效果;tb_integration_nms.v 把真实 sobel_edge+nms_thresh 串联,同一个阶跃边缘分别接低阈值(50)和高阈值(400)两个 nms_thresh 实例,验证两者边缘宽度都稳定在1像素——直接复现并验证修复了用户反馈的那个问题)。**用户还没编译验证效果**,理论上 LE/LAB 增量很小(方向缓冲只有2位宽,幅值缓冲480深×13位,远小于已用的 M9K 容量)。EDGE_THRESH 目前实际值是60(用户/linter调过)。

**质心追踪改成卡尔曼滤波,运动检测已从顶层摘除**:用户反馈"追踪的是红色物体,但实际使用中也会追踪人脸,而且十字心会在不同物体之间跳来跳去"——原因是 v2 的 `color_blob_tracker.v` 只用 EMA 对新测量做平滑,没有运动模型,画面里冒出一块新的同色区域(比如人脸落进了红色阈值范围)时,平均质心会被直接拽过去。同时用户要求"先把运动检测的代码不要调用,只调用质心追踪部分"。

已完成:
1. `camera_display_top.v` 里 `motion_detector`/`motion_overlay` 两个实例全部删掉(它们跟质心追踪本来就是互相独立的两条路径,只是叠加显示,删掉不影响追踪逻辑)。`overlay_marker` 现在直接吃 `disp_r/g/b`,不再经过运动高亮那层。qsf 里这两个文件的 VERILOG_FILE 行注释掉,文件本身保留在仓库里,想恢复随时能取消注释。
2. 新建 `kalman_1d.v`:一维稳态卡尔曼("alpha-beta")滤波器,X、Y 各一个独立实例。之所以不做完整协方差矩阵版本(每步都要用当前不确定度重新算增益,需要除法),是因为在过程/测量噪声大致恒定的前提下,完整卡尔曼滤波的增益最终会收敛到一组固定值——alpha-beta 滤波器直接用这组收敛后的固定增益(ALPHA_SHIFT/BETA_SHIFT,都是移位量,不需要除法),数学上是同一个东西的稳态简化版,不是凑合。状态是位置+速度的定点数(FRAC_BITS=5位小数),每帧(不是每像素)跑一次:先 `predict`(用上一帧的位置+速度外推,结果锁存成 `pred_pos` 撑满整个新的一帧,给搜索窗口定中心用),测量到手之后再 `update`(误差乘以增益去修正状态;没测量到就直接用预测值当新状态,靠运动模型"划水"过去;首次锁定/重新锁定时不走平滑,直接 snap 到测量值,跟 v2 EMA 版本处理重新锁定的思路一样)。
3. 重写 `color_blob_tracker.v`:去掉 EMA,接入两个 `kalman_1d` 实例。关键的"防跳变"逻辑:算出这一帧颜色阈值给出的原始质心后,跟 X、Y 两个滤波器的预测位置算一次曼哈顿距离(L1,不开方,跟 Sobel 幅值用 |Gx|+|Gy| 近似同一个思路),距离超过 `GATE_DIST`(默认90像素)就整体判定"这次测量不可信",两个滤波器都按"没测量"处理,继续按运动模型走,不会被拽过去——这是真正修复"跳到人脸上"这个问题的部分,单纯换卡尔曼滤波做平滑是治不好这个的。搜索窗口(`WINDOW_HALF`默认70像素)现在锁定的中心也从"上一帧的平滑位置"换成了"这一帧的预测位置",移动目标不会让窗口一直慢半拍。锁定状态用 `miss_streak` 连续丢失/拒绝帧数判断(默认15帧,超过判定丢失、下一帧退回全画面搜索),取代了 v2 里"这一帧没找到就立刻判丢"的逻辑。
4. 仿真验证:`tb_kalman_1d.v` 单独测滤波器本身(匀速目标能收敛、测量缺失时能靠速度继续外推、force_reset 能精确snap且速度归零),`tb_color_blob_tracker_v3.v` 用真实的 `color_blob_tracker.v`(含卡尔曼、含颜色阈值、含除法器时序)喂合成帧:一个匀速移动的红色方块 + 一个固定不动、放在搜索窗口之外的"人脸"干扰方块,验证追踪全程没被干扰方块拽走、`blob_pixels` 全程只有目标方块的像素数(干扰确实被窗口过滤掉了)。全部 ALL TESTS PASSED。
5. **用户还没编译验证效果**,颜色阈值本身(R_LO/R_HI/G_LO/G_HI/B_LO/B_HI,现在默认还是针对红色物体调的)没有改动,人脸误匹配的根源问题还在,只是现在就算误匹配上了也不会把十字心拽过去——后续如果想让人脸完全不被匹配,还是要单独调这六个颜色阈值(讨论过可以照 edge_threshold_tuner.py 的思路写一个摄像头颜色阈值调参脚本,还没写)。

**key2 改成一维条码识别(Code 39,仅数字0-9)**:用户讨论"高速产线场景下能否识别条码",并观察到"挥手时边缘检测/质心追踪效果变差,是不是不适应高速运动物体"——结论是运动模糊是传感器曝光时间(AEC)决定的光学限制,不是下游算法架构的问题;而条码识别本身不需要跟踪运动物体,工业产线上通常是扫描区固定、物体自己经过,天然适合"每帧独立解码、不留帧间状态"的思路(跟 color_blob_tracker.v 的跨帧预测正好相反)。用户最终拍板:"btn2 目前是区分黑白颜色(threshold_binarize),不需要了,直接改成识别一维条码"。

已完成:
1. 新建 `barcode_decoder.v`:固定扫描一行(`SCAN_ROW` 参数,默认136,画面纵向中央附近),`y8 < THRESH` 判定为"条"(暗)否则为"空"(亮),沿这一行做行程编码(run-length),行程长度跟 `WIDE_THRESH`(默认12px)比较分成窄/宽两档。Code 39 编码规则:每个字符(数字或起止符 `*`)固定9个元素(5条+4空,严格交替),其中恰好3个是"宽"。窄/宽 9bit 模式表不是凭记忆手写的——用 `pip install python-barcode` 装了一个成熟开源条码库,直接读它源码里 `barcode/charsets/code39.py` 的权威编码表转换验证过(每个数字模式都恰好3个宽位,符合"3 of 9"结构规则)。3状态状态机(`S_HUNT`找起始符→`S_SKIP_GAP`吃字符间的窄间隔→`S_CHAR_COLLECT`数满9个元素):等到停止符(同样是 `*` 模式)才认为一次解码完成,`barcode_valid` 打一拍脉冲,`digit_count`/`decoded_digits`(每个数字4bit,从低位开始packing)锁存结果。`frame_pulse` 时清空所有状态——不留跨帧记忆,每帧独立重新扫描识别,呼应"固定扫描区、物体自己经过"的产线场景。
2. 设计阶段主动抓到并修掉一个同拍寄存器"读到旧值"的坑:一开始想直接用 `hist_nw`(9bit 移位历史寄存器)在它自己被非阻塞赋值更新的同一拍里做起始符/字符判断,会读到更新前的旧值——改成用组合逻辑 `hist_nw_next`/`pending_is_start`/`pending_char` 三个 wire(基于"如果这一行程现在收尾,寄存器接下来会变成什么"来算),同拍内所有判断都统一用这三个 wire,不直接用 `hist_nw` 本身或临时重复推导表达式。这个坑是写代码时主动发现修复的,没有仿真复现过错误版本。
3. 写 `tb_barcode_decoder.v` 仿真验证:先在沙箱里用 python 脚本按验证过的 Code 39 编码表,生成"*42*"(起始符+数字4+数字2+停止符)测试条码对应的行程序列(窄6px/宽18px/字符间隔6px/两端40px静区,共41段458px),再转成 Verilog `draw_run()` 调用序列喂给仿真。踩了一个测试台本身的坑:一开始用 DUT 的 `frame_pulse` 清空"已看到有效解码"这个校验用寄存器,结果 `barcode_valid` 脉冲发生在扫描行中途(帧内),而 `frame_pulse` 在这一帧结尾才发,清空动作把刚锁存的结果冲掉了——改成测试台自己在每帧开始前手动脉冲一个独立的 `clear_seen` 信号,不复用 DUT 的 `frame_pulse`。修完后:Test 1(条码帧)正确解出 `digit_count=2`、`decoded_digits` 低4位=4/次4位=2;Test 2(纯背景无条码帧)全程 `barcode_valid` 不出现。ALL TESTS PASSED。
4. 接入顶层:`camera_display_top.v` 里删掉 `threshold_binarize` 实例和 `bin_r/g/b` 相关线,新增 `barcode_decoder` 实例(`clk_9m`/`sys_rst_n`/`lcd_de_w`/`lcd_frame_pulse`/`disp_y`/`pixel_x_w`/`pixel_y_w` 接入,跟其它像素级模块一致)。key2 视觉呈现:直接透传实时画面,在 `SCAN_ROW` 那一行画一条参考线——黄色表示正在扫描寻找,解码成功后短暂(`bc_hold_cnt`,约90帧,纯视觉用不影响时序)变绿,提示"对准这条线放条码,变绿说明读到了"。`digit_count`/`decoded_digits` 目前只是端口输出,还没有做屏幕数字文本渲染,先留给 SignalTap 或后续接数码管/文本叠加用。`threshold_binarize.v` 文件本身没删,qsf 里的 VERILOG_FILE 行照 motion_detector.v 的先例注释掉,想切回纯黑白视图随时能恢复。qsf 加了 `barcode_decoder.v`。
5. **用户还没编译验证效果**。V1 范围限制:只认数字0-9(没做字母/符号),单扫描行(没有多行投票增强鲁棒性),`WIDE_THRESH` 是固定绝对像素阈值(假设条码在画面里的相对大小基本不变,如果摄像头到条码的距离经常变就需要跟着重调,甚至做自适应模块宽度估计)。

**key2 从 Code 39 改成 EAN-13/UPC-A**:用户实际测试 Code 39 版本时反馈"摁了Key2，但是把条形码放到线上的时候好像没什么反应",追问后确认测试用的是"在方形饮料盒子上的一维条形码"——这就是根本原因:零售商品包装印的一维码几乎全是 EAN-13/UPC-A,不是 Code 39(Code 39 是工业/物流场景,资产标签、门禁卡那类,消费品包装基本不用)。两种编码结构完全不同,Code 39 只有窄/宽两级,EAN-13 每根条纹是 1~4 个模块宽的四档,不是阈值没调好,是从设计上就无法识别——放多久都不会有反应。用户确认要改成 EAN-13/UPC-A。

已完成:
1. 新建 `ean13_decoder.v`:比 Code 39 复杂不少,因为 EAN-13 每个数字用7个模块拆成4段行程,每段可以是1/2/3/4个模块宽(同一个物理模块宽度X),不能再用简单的窄/宽二分。做法是动态估计模块宽度:起始哨兵"101"(3个模块,每个恰好1X)3段行程互相接近(比值检测,不开方:`2*max<=3*min`),取三段的近似平均(`sum*683>>11`≈`sum/3`,一次移位加法搞定,不占时序)作为 `X_est`;后续每段行程通过 `2*run_width` 跟 `3*X_est/5*X_est/7*X_est` 比较(1.5X/2.5X/3.5X 三个边界,交叉乘2避免小数)分类成1~4模块。左组6个数字用A/B两套7位模式表(哪个数字用A还是用B,由标准里没有直接编码、需要反推的"隐藏"第13位/最前面那位数字决定),右组6个数字用C表,中间哨兵"01010"和结束哨兵"101"只计数跳过。三套编码表+A/B模式反推表全部来自 `pip install python-barcode` 装的库源码 `barcode/charsets/ean.py`,转成行程长度元组后脚本验证过20个左组、10个右组模式互不冲突。额外验证:反推出的最前面那位数字(`leading_digit`)+标准的加权 mod10 校验位(权重1/3那套,标准做法)都要通过才算解码成功——这是白拿的,13位数字全解出来之后校验位验证不需要额外硬件成本,能挡掉大部分因模块宽度分类错误而蒙出一个"看起来合理但其实错"的号码。UPC-A 不用单独处理:UPC-A 本质是隐藏最前面那位数字=0(对应"AAAAAA"模式)的 EAN-13,EAN-13 解码器直接就能读。
2. 写 `tb_ean13_decoder.v` 仿真:用 python-barcode 自己的 `EuropeanArticleNumber13.build()` 生成一个真实条码(ean=4006381333931)的95模块行程序列,转成4px/模块的像素行程喂仿真。**踩了一个坑并修复**:第一版仿真结果解码到状态机全程走完(左组6个、右组6个数字全部正确解出,数值跟预期完全一致),但 `ean_valid` 始终不拉高——加了内部信号 dump 之后发现是 `leading_digit` 反推表的位序搞反了:硬件里 `parity_bits[digit_idx]` 是把第0个左组数字的A/B位放在寄存器最低位,但生成反推表时脚本是直接按 python-barcode 打印的模式字符串"从左到右=从高位到低位"转的,两者顺序正好相反,导致反推表怎么都命不中。修复:反推表的6位字面量要按"第5个数字的位在最左(最高位)、第0个数字的位在最右(最低位)"重新生成(即模式字符串先 reverse 再转0/1)。修完后 Test 1(完整解码 4006381333931,13位数字+校验位全部正确)、Test 2(纯背景帧不误触发)ALL TESTS PASSED。
3. 接入顶层:`camera_display_top.v` 里 `u_barcode` 实例从 `barcode_decoder`(Code 39)换成 `ean13_decoder`,端口名同步改(`barcode_valid`→`ean_valid`,`decoded_digits` 从32位/8个4bit数字变成52位/13个4bit数字,去掉了 `digit_count` 端口,EAN-13 固定13位不需要单独计数)。可视化逻辑(扫描参考线黄→绿、`bc_hold_cnt` 视觉停留)原样复用,不用改。`barcode_decoder.v`(Code 39)本身不删,qsf 里连同 `threshold_binarize.v` 一起注释掉 VERILOG_FILE 行,想切回随时能恢复。qsf 加了 `ean13_decoder.v`。
4. **用户还没编译验证效果**。V1 范围限制:单扫描行(没有多行投票),模块宽度估计只在成功找到起始哨兵那一刻算一次(不会随着扫描过程中途重新校准,如果条码在画面里有明显透视变形/倾斜导致模块宽度不均匀会解码失败),`MIN_MODULE_PX`(默认3px)是唯一的防噪声下限,没有上限保护(理论上背景里凑巧出现三段接近等宽的东西也可能误触发进入左组解码,但后续13位数字+校验位这道关卡会把绝大多数误触发挡在最后一步拒绝掉,不会真的显示错误号码)。

**LAB 超限问题已定位并修复(待用户编译验证)**:真正原因不是 M9K 推断"被拒绝",而是 `sobel_edge.v` 的 `line_a/line_b` 和 `motion_detector.v` 的 `luma_mem/changed_mem` 用的是组合逻辑读(`wire = arr[idx]`,同一拍内地址给出立刻拿到数据)。M9K 硬件的读端口物理上只支持同步读(这一拍给地址,下一拍数据才出来),组合读这种写法不管加不加 `ramstyle` 属性都不可能映射上 M9K——Quartus 只能老实地用几百个寄存器+一个巨大多路选择器在 LE 里"手搭"一个能瞬间查表的假内存,这正是吃掉几百上千 LE 的元凶。之前那次 ramstyle=M9K 的"修复"编译前后 LAB 数字一模一样(858),现在回头看就是因为它对组合读的场景根本不起作用。

已修复:两个模块的内存读都改成寄存器化同步读,写端口相应延迟一拍对齐(sobel_edge.v 新增 la/lb/px_d1/py_d1/y8_d1/de_d1 延迟链;motion_detector.v 新增 flushing_d1/flush_addr_d1/cur_avg_d1 延迟链——注意 motion_detector.v 现在已经不在顶层实例化了,这个修复还在文件里但暂时用不上)。Sobel 已重新在 camera_display_top.v 和 qsf 里启用。**下一步:用户需要重新完整编译一次,确认 LAB 数量是否真的降到 645 以内**——如果还超,说明还有其他大头没找到,需要 Quartus 的 Analysis & Synthesis Resource Usage Summary 逐模块排查,不要再猜。运动检测摘除后 LAB 应该还能再降一点。

**二值化CNN(BNN)手写数字识别——独立子项目,未接入摄像头主流程**:老板要求"在这颗芯片上实现CNN",用户确认目标是当前的EP4CE10(不是之前讨论换的ZYNQ板子)。因为摄像头对焦和SD卡都还没解决,用户明确要求先不管这两个,只在Verilog里把二值化CNN流程跑通,用仿真+硬编码测试图片验证,不依赖摄像头/SD卡。

已完成:
1. 训练:沙箱里用python(numpy手写BinaryConnect式STE训练,没装得动PyTorch就手撕了前向+反向)在真实MNIST数据集(标准mnielsen/neural-networks-and-deep-learning仓库的mnist.pkl.gz,50000训练/10000测试,不是编的数据)上训练了一个仿smallNet规模(用户选择的V1范围)的极简二值化网络:conv(1个2x2 filter,valid卷积)→BN折叠阈值+sign二值化→2x2 maxpool→conv(1个2x2 filter)→BN折叠阈值+sign→2x2 maxpool→flatten(36)→dense(10)→argmax,输入图像本身也二值化(像素>0.5→+1,否则-1),总共约380个参数。训练踩了一个坑:第一版没做BinaryConnect标准的"影子权重裁剪到[-1,1]"这一步,导致权重跑出STE梯度的有效区间后梯度永久归零,训练大幅震荡(验证集准确率在40%~59%之间反复,还多次崩到10%随机水平)——加上裁剪+记录最佳验证集checkpoint(而不是直接用最后一轮)后稳定住,最终选用14轮训练的最佳checkpoint,测试集准确率58.44%。这个数字不高(远不如通常几万参数规模的BNN论文能到的95%+),但是用380个参数、完全二值化(连输入图像都二值化了)跑出来的真实数字,过程可查(train_bnn.py),V1目标是"流程能跑通"不是刷分,后续想要更高准确率可以加大每层filter数量。
2. 硬件等价性验证:BN(batchnorm)训练完之后,标准做法是把BN的scale/shift折叠进sign()激活前的一个整数阈值比较,推理时完全不需要除法/乘法。折算下来两层卷积的判决规则精确落在"4选2"和"4选3"两个干净的popcount(XNOR一致位计数)边界上(`verify_and_export.py`里解出来的),dense层训练出来的偏置全部小于0.16——由于popcount每变化1对应等效实值分数变化2,这么小的偏置永远不可能翻转argmax判决,所以直接丢弃,最终分类器简化成"看哪个输出神经元的popcount最大"。在丢弃偏置+折算成纯整数比较之后,专门写了一版纯Python整数版前向(`verify_and_export.py`),在1000张测试图片上验证准确率58.30%,跟浮点参考模型的58.44%基本一致(抽样误差范围内)——确认这一层"从BN浮点折算成纯整数XNOR+popcount+比较"的简化没有引入额外误差,这才敢往Verilog里搬。
3. 新建 `bnn_core.v`:整个前向过程真的一次乘法器都没用——卷积是XNOR+popcount(4bit输入窗口异或权重、数1的个数跟阈值比),池化是2x2窗口内4个二值位的OR(因为±1取max等价于"是否有任意一个是+1"),dense层是36位XNOR+popcount。用一个状态机顺序过完每一层(每层一个位置计数器,一个位置一拍,S_CONV1→S_POOL1→S_CONV2→S_POOL2→S_DENSE→S_DONE),单张图约1040拍,给定的时钟随便多少都绰绰有余。权重(4bit×2个卷积核+36bit×10个dense行)全部是硬编码localparam,来自训练导出的真实数值,bit顺序专门写了个round-trip校验脚本确认没搞反(第一版差点又犯"图案反推表位序搞反"那种坑,这次仿真前先用Python自己解码校验过)。
4. 写 `tb_bnn_core.v` 仿真验证:喂了7张真实MNIST测试集图片(不是手画的,是从mnist.pkl.gz测试集里挑出来的真实样本,`verify_and_export.py`生成),覆盖6个不同数字类别的正确分类案例,外加1个纯Python参考模型也判错的案例(真实标签2,预测成6)特意留着——确认Verilog不仅"答对时对",误判的那个也精确复现了同一个错误答案,证明硬件实现跟Python参考模型是逐bit等价的,不是巧合对上几个简单案例。ALL TESTS PASSED,7/7跟Python算出的预期(含那个错的)完全一致。
5. 加进qsf、临时把TOP_LEVEL_ENTITY切到bnn_core跑了一次真实Analysis & Synthesis(因为沙箱没有Quartus,只能这样借用户的手跑一次拿真实数字,不能瞎猜)。结果:Total registers=1898(跟寄存器位数的手估几乎精确对上)、Total memory bits=0、Embedded Multiplier=0(确认零乘法器设计成功),但 **Total logic elements=5776——单这一个模块就吃掉EP4CE10全片10320 LE预算的56%**,远超预期,且完全没法跟摄像头主流程共存(camera_display_top.v 现有的DVP/SDRAM/LCD/Sobel/追踪/EAN-13 一起还得挤进剩下的44%)。
6. **定位到LE爆炸的根因,和当年 sobel_edge.v/motion_detector.v 的LAB超限同源(见上面"LAB 超限问题"那条)**:v1把img/a1/p1/a2这几个图像/特征图缓冲区都声明成扁平的一整条向量寄存器(`reg [783:0] img;`),然后用运行时算出来的位偏移去位选(`img[(cy+0)*28+(cx+0)]`)。这种写法在Quartus眼里根本不是"字数组",就是一整条寄存器加一个运行时位下标,只能老实地在LE里手搭一个跟向量总宽度(784)成正比、逐次动态访问都要复用一遍的巨型多路选择器/译码器——这才是吃掉5776个LE的真正元凶,不是卷积本身的XNOR+popcount逻辑(那部分很小),寄存器总数(1898)、M9K(0)、乘法器(0)这几个数字反而全部符合预期,说明存储量本身从来不是问题,问题是"怎么访问"。
7. **已重写(2026-07-16),仿真验证功能完全不变(7/7跟重写前逐一致,含误判那张)**:把img/a1/p1/a2改成真正按"行"寻址的字数组(`img_mem[0:27]`每个字28位、`a1_mem[0:25]`每字26位、`p1_mem[0:12]`每字13位、`a2_mem[0:11]`每字12位),配合同步双行读取(每层2x2窗口需要相邻两行,`raddr0`/`raddr1`指向要读的两行,经ADDR→WAIT→SCAN三态让M9K风格的同步读延迟落地后再用),照搬 sobel_edge.v/gaussian_blur3x3.v/nms_thresh.v 已经验证过的"行缓冲+同步读"套路。image_in本身也没有再用动态位选加载——改用784位移位寄存器,每拍固定取最低28位再整体右移28位(移位量是常数,纯布线不占LE),彻底把一次性加载这一步的动态位选成本也去掉了。现在唯一剩下的运行时下标,是"已经取到的单行寄存器内部按列取值"(最宽28位,比之前784位的向量小了近28倍)和"窄(≤26位)行累加器内部按列写入"这两处,规模跟之前完全不是一个量级。
8. **重写已用户真实综合确认生效**:第一次结果 Total logic elements=4713,紧接着用户又贴了一次数字变成 2860——两次之间具体改了什么设置(比如 Analysis & Synthesis Settings 的 Optimization Technique 从 Balanced 换成 Area)用户没说清楚,没有确认到,**这里如实记录两个数字都真实出现过,以 2860 为准**(用户没有否认这是最终结果)。不管中间发生了什么,相比重写前的 5776 都是大幅下降,2860/10320≈28%,健康,可以跟摄像头主流程共存。qsf 的 TOP_LEVEL_ENTITY 已改回 `camera_display_top`。
9. **真实硬件验证(2026-07-16)**:仿真+资源数字都只证明"RTL模型"和"综合报告"没问题,不证明真实硅片跑出来是对的——用户选择做真机验证而不是止步于此。新建 `bnn_demo_top.v`:独立顶层(不影响 camera_display_top),复用 tb_bnn_core.v 里同样7张真实MNIST测试图,KEY1(M15)循环切换图片并重新触发分类,4个LED(E10/F9/C9/D9)二进制显示 digit_out。特意不用固定死的单张图片,而是用 KEY1 做运行时选择——单一常量输入的话 Quartus 完全可能在综合时把整个 bnn_core 计算过程常量折叠成一个写死的答案,那样资源数字和demo都没有意义,不是真的在跑核心的算力路径。开机自动跑一次 image 0 分类(不用按键就能看到第一次结果),LED 序列预期:7,1,0,4,9,3,6,再回到7——那个"6"不是bug,是原本仿真里就复现出来的那个误判(真实标签2),真机上如果也display出6而不是别的数字,恰好是"真实硬件和仿真逐bit一致"最有力的证据。`tb_bnn_demo_top.v` 仿真验证过(含debounce电路本身,不是走捷径直接戳内部状态),7张全部依次匹配预期,含误判和绕回image 0都对。qsf 加了 `bnn_demo_top.v`,端口名(clk/rst_n/key1_n/led)特意跟 qsf 里已有的全局(非 -entity 限定)引脚分配完全同名,不需要新增 location assignment。**第一次真机测试:编译干净(Top-level Entity Name确认是bnn_demo_top,1507 LE/15%,7引脚全部分配成功),但LED毫无反应,按复位和KEY1都没用**。先排除了烧录/板子问题:用户确认同一块板子上 `camera_display_top` 工作正常(同样用到 clk/rst_n/KEY1 这几个引脚),问题specific在 `bnn_demo_top`。定位到疑点:`test_img`/`true_label` 原来是用 `reg` 数组 + `initial` 语句块赋值的——这种写法仿真器会老实执行,但真实 Quartus 综合流程里,`initial` 块驱动的数组能不能可靠变成硬件里真正的上电初始值不是100%保证的(不像 `localparam` 那样是纯组合逻辑常量),如果这份测试图数据在真机上没被正确加载,所有 `img_idx` 会读到同一份(很可能全0的)图,不管怎么按 KEY1 算出来的答案都不会变——跟"怎么按都没反应"的现象吻合。**已修复**:把 `test_img`/`true_label` 改成跟 `bnn_core.v` 自己的 `wsel` 权重表同样的写法(`IMG0`~`IMG6` 七个 `localparam` 常量 + `case` 语句按 `img_idx` 选择),纯组合逻辑选择,不依赖 initial 块到硬件RAM的加载,同时因为选择依据还是运行时寄存器 `img_idx`,防常量折叠的设计意图不受影响。`tb_bnn_demo_top.v` 重新跑过,7张图+误判+绕回全部依旧 ALL TESTS PASSED,功能没变。**修复后重新编译烧录,真机验证成功**:开机自动分类image 0,LED正确显示`0111`(=7,led3灭/led2,1,0亮);按KEY1依次验证,序列跟预期(7,1,0,4,9,3,6,绕回7)完全一致,含那个故意留的误判案例(真实标签2,LED显示6)。**至此"训练(PC/沙箱)→硬件等价性验证(纯整数前向)→bnn_core.v实现→仿真验证→真实Analysis&Synthesis资源占用(2860 LE)→bnn_demo_top.v真机验证"整条链路全部跑通并在真实硅片上确认正确**,可以作为"这颗EP4CE10上能跑CNN"的完整证据向老板汇报。
10. **还没接入摄像头主流程**。这是有意为之:用户明确要求先脱离摄像头/SD卡独立验证,真机验证也是用硬编码测试图片而不是摄像头画面。下一步如果要接实机摄像头输入,还需要:(a)把摄像头实时画面下采样/二值化成28x28,这个前处理现在还没写;(b)镜头对焦问题不解决,摄像头这条路线上的任何后续工作都没法真正验证效果;(c)大概率还需要跟主流程的其它功能模块(Sobel/追踪/EAN-13)分时复用/二选一,而不是同时全部塞进10320 LE里。

**BNN 正式接入摄像头主流程(2026-07-16)**:用户问"这个是给的固定照片识别,还是你直接告诉了答案?我现在需要联通摄像头-fpga-LED显示屏"——先澄清了 bnn_demo_top.v 的分类过程是真算的(误判案例在真机上原样复现就是证据),但输入图片确实是硬编码的7张测试图,不是摄像头实时画面,这正是用户现在要补上的部分。用户要求摄像头检测数字→FPGA CNN识别→显示在数码管或LED屏。问了两轮澄清:(1) 镜头对焦问题要不要先修——用户选"先不管,直接写代码";(2) 画面里数字定位方式——用户选"固定取景框"(而不是自动检测数字位置)。

已完成:
1. 新建 `roi_binarize_28x28.v`:接的信号跟项目里其它像素级模块完全一样一套(`clk_9m`/`sys_rst_n`/`lcd_de_w`/`lcd_frame_pulse`/`disp_y`/`pixel_x_w`/`pixel_y_w`),固定裁 480x272 画面正中央 224x224(X0=128,Y0=24,224=28×8整除无余数),每个 8x8 块按"块内只要有一个暗像素就算 1"下采样成 28x28 二值图(不用平均——平均会把细笔画糊掉)。极性刻意做成"暗=1(笔画)":真实纸面是白底黑字,跟 MNIST 训练用的"暗背景亮笔画"约定正好相反,如果直接照抄训练时的极性会把整张图识别反,这里对齐了 bnn_core.v 真正学到的约定(跟 threshold_binarize.v/barcode_decoder.v 已经用过的"暗=1"是同一个思路)。架构上又一次刻意避开了 bnn_core.v v1 踩过的坑:28x28 结果存成真正按行寻址的字数组(`img_mem[0:27]`,每字28位),行内累加器 `accum_row` 只有28位宽,行程运行到新的块行时才把上一行 flush 进 `img_mem`(用组合逻辑 next-value 写法算好"这一行程收尾后寄存器该是什么"再赋值,不读同拍刚写的旧值,跟 bnn_core.v/barcode_decoder.v 已验证过的套路一致);读出 784 位结果时是28个字的静态(编译期常量下标)拼接,不是动态位选。`img_valid` 在 `frame_pulse` 后一拍才拉高,这时最后一行也已经 flush 完,读到的是完整帧;而且要等到下一帧真正扫到 ROI(第24行)才会开始覆盖 `img_mem`,中间有一大截行/场消隐的余量,不会读到"半新半旧"的撕裂帧。仿真 `tb_roi_binarize_28x28.v`(合成两帧480x272全画面光栅:一帧在指定8x8块位置放一块暗色、其余全亮,一帧全亮无暗块)ALL TESTS PASSED——暗块位置对应的那一位精确置1、其余783位全0;全亮帧下一帧图像正确归零(没有跨帧残留)。
2. 新建 `seg7_decoder.v`:数字(0-9)转七段码,`seg[6:0]={a,b,c,d,e,f,g}`。极性通过 `ACTIVE_LOW` 参数做成可配置,默认1——问用户澄清后确认 LG3661BH 是共阳极、段位为低电平点亮("对应字段的引脚为低电平时,对应字段点亮"),标准共阴极("1=点亮")的段码表算好后按需要整体取反即可,不用重新编一套表。多加了 `digit_valid` 输入,拉低时强制熄灭(不显示上电或复位后还没跑完第一次分类时的垃圾值)。仿真 `tb_seg7_decoder.v` 核对0-9全部10个字型(active-high和active-low两个实例对照检查互为取反)、`digit_valid=0` 全灭、越界数字(测了12)也全灭,ALL TESTS PASSED。
3. 接入 `camera_display_top.v`:新增一段"BNN摄像头流水线":`roi_binarize_28x28` 常驻跑在背景,`img_valid` 每帧触发一次一个小状态机(`BNN_IDLE→BNN_START→BNN_WAIT`)去起 `bnn_core`(跟 `bnn_demo_top.v` 里那个 FSM 是同一个思路,只是触发源从按键换成了 `img_valid`)分类,分类完锁存 `bnn_digit`/置位 `bnn_result_valid`,喂给 `seg7_decoder`。这条路径完全独立于 key1/2/3 那三个按钮选的显示模式 mux——不碰 `final_r/g/b`/`disp_mode`,是真正"常驻后台"的分类器,跟三个按钮已经占用完的模式选择互不冲突(用户在设计讨论阶段就明确这个决定,没有再单独确认,因为三个按钮确实都已经用掉了,没有更省事的接法)。用 iverilog 对整个 `camera_display_top.v`(含新模块)做了一次纯语法/端口连线检查(Analysis-only,没跑仿真波形,因为完整跑一次480x272摄像头光栅+SDRAM+PLL的行为级仿真这个项目里从来没搭过,PLL/SDRAM 用的是 Quartus 专用宏功能 altpll/dcfifo,iverilog 本来就编不出来)——除了这两个已知的、跟这次改动无关的宏功能报"unknown module"之外,新增的 `roi_binarize_28x28`/`bnn_core`/`seg7_decoder` 三处例化全部端口宽度、连线正确,没有报错。
4. qsf:加了 `roi_binarize_28x28.v`/`seg7_decoder.v` 两个 `VERILOG_FILE`。**顺手把 TOP_LEVEL_ENTITY 从遗留的 `bnn_demo_top` 改回了 `camera_display_top`**(bnn_demo_top 真机验证那次跑完之后一直没切回来,这次要继续改 camera_display_top 所以顺手切回)。
5. **数码管引脚已确认,不是独立飞线的 LG3661BH,而是 AX4010 板载6位数码管**:第4条那轮问引脚编号,用户回复"LG2661BH"没给出引脚,当时判断不清是型号笔误还是别的意思;下一轮用户直接上传了《Alinx AX4010 User Manual.pdf》并贴出 p.31"Digital tube pin assignment"表格截图,才发现真实硬件跟最初设想的不一样——不是接一颗独立 LG3661BH 靠8根飞线接7段+小数点,而是板子上现成的一块6位数码管模组,`DIG[7:0]={dp,g,f,e,d,c,b,a}` 是6位共用的段线,`SEL[5:0]` 是每一位各自的位选使能线(经开关管切到该位的公共端)。**架构相应调整**:camera_display_top.v 的顶层端口从 `seg7[6:0]`/`seg7_dp` 改成 `dig[7:0]`/`sel[5:0]`,`seg7_decoder` 的输出内部先接到 `seg7_pattern`/`seg7_dp_pattern` 两根线,再拼进 `dig`;因为只需要显示分类结果这一个数字,不需要真正做6位扫描复用——`sel[0]`(最右边那一位)常态选中,其余5位常态不选中,`dig` 静态驱动,其余5位物理上就是暗的,省掉了扫描FSM。qsf 按手册p.31的表格逐个 `set_location_assignment`:DIG[0..7]=R14/N16/P16/T15/P15/N12/N15/R16,SEL[0..5]=N9/P9/M10/N11/P11/M11,配套的 `IO_STANDARD "3.3-V LVTTL"` instance assignment 也一并加上。跟现有引脚表(摄像头/LCD/SDRAM/SD/LED/KEY)做了一次去重检查,这14个新引脚没有跟任何已用引脚冲突。用 iverilog 重新过了一次顶层语法/连线检查,除了已知跟这次改动无关的 altpll/dcfifo 宏功能报"unknown module"外,dig/sel 新增连线正确无报错。
6. **用户还没编译验证。已知的开放问题,按优先级排:**
   (a) **`SEL[5:0]` 的有效电平(是低电平选中还是高电平选中)是假设出来的,手册这张表只给了引脚号和"第几位数码管"的对应关系,没写 SEL 的极性**——按 `DIG` 已确认的共阳极低电平点亮的惯例(数码管公共端一般靠开关管切换,配合共阳极多是低有效)假设 `SEL` 也是低电平选中(`camera_display_top.v` 里 `SEL_ACTIVE_LOW` localparam,当前=1),但这是推测,不是用户确认过的,**编译烧录后如果6位数码管完全不亮或者点亮的是别的位而不是最右边那位,第一个该查的就是这个假设是不是反了**,改 `SEL_ACTIVE_LOW` 这一个 localparam 就能反过来试。
   (b) 镜头对焦问题仍未解决(用户明确选择的"先不管"),意味着即便这条链路电路本身完全正确,摄像头拍到的手写数字如果本来就没对上焦、模糊成一片,ROI 二值化出来的28x28大概率是一坨糊的,bnn_core 认不出来也不奇怪——这不是代码bug,是光学前提没满足,真要验证识别效果得先解决对焦。
   (c) `THRESH`(暗/亮阈值,默认100)、ROI 位置/大小(224x224 居中)都还是纸面设计值,没有拿真实手写数字在真实光照下试过,大概率需要跟当年 `edge_threshold_tuner.py`/颜色阈值调参一样过一轮实测微调,尤其是如果实际书写的数字大小/粗细跟 MNIST 训练集差异明显(真实手写字通常比 MNIST 28x28 里凝练出来的笔画粗得多),8x8块「有暗就算1」的下采样规则可能需要跟着调。
   (d) LE预算:`bnn_core.v` 单独约2860 LE(28%),现在又加了 `roi_binarize_28x28.v`(28深28位M9K风格行缓冲,LE量级应该远小于 bnn_core 本身,但没实测过)一起跟主流程(DVP/SDRAM/LCD/模糊/Sobel/NMS/追踪+卡尔曼/EAN-13)编译,总 LE/LAB 有没有超预算,还是那句话"编译一次拿真实数字,不要猜"。

**用户编译烧录后测试反馈三个问题,已修复(2026-07-17)**:用户实际测试反馈:(1)"在没有数字显示的时候,digital tube 也会显示数字";(2)"LCD上的图像都是镜像的,镜像是否会影响识别";(3)"我希望在LED显示屏上,有一个绿色方框,可以框出固定识别区域在哪里"。

已完成:
1. **问题1(空白帧误显示数字)根因**:bnn_core.v 没有"拒绝/未知"类,dense层永远argmax出0-9中的一个,哪怕输入ROI是空白纸/背景也会强行给出一个答案。**修复**:`roi_binarize_28x28.v` 新增 `ink_count`(16位)输出端口,统计当前帧ROI内原始暗像素个数,复用同一个 always 块顺带累加(不是额外的popcount树,成本很低),跟 `img_valid` 同拍打出。`camera_display_top.v` 的BNN FSM在 `BNN_IDLE→BNN_START` 转换时锁存 `bnn_ink_ok=(ink_count>=MIN_INK_PIXELS)`(阈值默认150,是ROI总面积50176像素的约0.3%,一个粗糙、未实测的"有没有墨迹存在"判断,不是真正的数字/非数字分类器),分类完成时 `bnn_result_valid<=bnn_ink_ok`——没有足够暗像素就不置位,`seg7_decoder` 的 `digit_valid` 拉低,数码管熄灭。仿真 `tb_roi_binarize_28x28.v` 新增 `ink_count` 断言(8x8暗块→精确等于64;全亮帧→0,不留上一帧残留),ALL TESTS PASSED。
2. **问题2(镜像)排查**:确认会影响识别——手写数字左右不对称(2、3、5、7等镜像后完全变形),BNN训练用的是正常朝向的MNIST,送进去镜像图必错,不是纸面猜测。查 `ov5640_reg_table.v` 发现 0x3821(水平镜像)/0x3820(垂直翻转)当前配置的是"关闭"(0x01/0x41),说明用户看到的镜像不是这两个寄存器打开导致的,大概率是摄像头模组物理安装朝向本身导致原始画面就是左右颠倒的(这正是这两个寄存器设计出来要补偿的场景)。**修复**:把 0x3821 从 0x01 改成 0x07(打开水平镜像位)。这个寄存器在表里出现两次(entry 17初始配置、entry 225在输出窗口设置完之后再次覆盖——entry 225是真正生效的最终值),两处都同步改了。LCD预览和BNN识别读的是同一路像素流,这个寄存器改动对两者同时生效,不需要在RTL里分别处理。**用户还没编译验证**——只能烧录后肉眼看LCD上文字/手写是否变正常朝向来确认;如果方向猜反了(变得更镜像而不是更正常),把两处 0x3821 都改回 0x01。
3. **问题3(绿色ROI取景框)**:`camera_display_top.v` 在三个显示模式 mux 出来的 `final_r/g/b` 和真正送进 `lcd_driver` 的信号之间插入一层:算出当前像素是否落在 ROI(128,24)-(351,247) 的边框上(2px描边、不填充,`roi_box_pixel` wire),是就强制输出纯绿色(0,255,0),否则透传 `final_r/g/b`。`lcd_driver` 的 `data_r/g/b` 端口改接这层新的 `disp_final_r/g/b`。这个框叠加在**所有**三个显示模式上(不只是默认追踪模式),因为BNN分类器本来就是独立于key1/2/3常驻运行的,不管选哪个模式都该能看到该把手写数字放哪。ROI坐标跟 `roi_binarize_28x28.v` 用的默认参数(X0=128,Y0=24,224x224)完全对齐,没有另起一套数字。
4. 三处改动都过了 iverilog 顶层语法/连线检查(除已知的 altpll/dcfifo 宏功能报错外无新增错误),`roi_binarize_28x28.v`(含新 ink_count 断言)、`seg7_decoder.v` 的仿真都重新跑过,ALL TESTS PASSED。**用户还没编译验证任何一处**。
5. **这一轮修复过程中,camera_display_top.v / roi_binarize_28x28.v / tb_roi_binarize_28x28.v / ov5640_reg_table.v / CameraCapture.v 全部又发生了"Edit/Write工具确认成功、bash读回却是旧的/截断的版本"这个反复出现的坑,而且这次更隐蔽**:camera_display_top.v 被截断在 BNN FSM 的 `always` 块开头(卡在 `if (!sys_rst_n) begin` 那一行,后面全部丢失),单独用 iverilog 编译这一个文件直接报语法错误。更棘手的是,这次连续4轮 bash 校验(wc -l/md5sum)都稳定复现同一个**截断后的、错误的**版本,不是"偶尔读到旧状态"——过去总结的"连续校验几次确认稳定就可以往下走"这条经验规则在这次并不可靠,**稳定不等于正确**。同样的问题级联发生在 `ov5640_reg_table.v`(截断在229行左右,少了后半段253个条目里大约90个)和 `CameraCapture.v`(整个文件是旧的/不知来源的版本,而且这个文件这次session压根没编辑过,纯粹是bash挂载层自己没同步)。**更重要的是新摸索出的一条经验**:iverilog 把多个文件一起编译时,如果排在前面的某个文件(比如 camera_display_top.v)本身有真实的截断/语法错误,解析器会在那里出错后"带着错误状态"继续解析后面传入的文件,导致报错信息完全指向**后面那些其实没问题的文件**(联合编译时报出 `roi_binarize_28x28.v`/`CameraCapture.v` 一堆 syntax error,但把这两个文件单独拿出来编译其实是干净的)——**排查步骤应该是先把每个文件单独 `iverilog -tnull single_file.v` 编译一次定位真正出错的文件,不要直接信联合编译报错信息里的文件名**,这是这一轮才摸索出来的新经验,之前没意识到错误会跨文件级联误导排查方向。修复流程不变(Read工具读真实内容→heredoc强制整体重写→重新校验),但这次额外确认:重写后除了连续多次校验字节数/md5一致外,**必须再跑一次单文件 `iverilog -tnull` 编译作为最终确认**,不能只看"多次读取结果一致"就当作正确——一致的坏状态和一致的好状态在校验层面看起来是一样的。

**digital tube 段位顺序bug已修复(2026-07-17)**:用户测试上一轮三处修复后追问"digital tube显示的为什么不全是数字？为什么还会有非数字的显示"。排查:先查 `bnn_core.v` 的 `S_DENSE` argmax 逻辑——`dk` 计数器严格 0-9 循环,`best_k`/`digit_out` 只能来自 `dk` 或复位值,结构上不可能输出10-15的非法码,排除了分类器本身出错的可能;`seg7_decoder.v` 也已经用测试台独立验证过0-9全部字形正确、`digit_valid=0`和越界输入都能正确熄灭。问用户"非数字显示具体是什么样子",用户确认"单个位但图形不像数字"——只有一个位点亮(说明SEL选中逻辑本身工作正常),但点亮的段组合不是任何0-9字形。这排除了SEL极性导致多位重影的猜测,把范围收窄到 `seg7_decoder.v` 输出到物理 `dig` 引脚之间的接线。

根因:`camera_display_top.v` 里 `assign dig = {seg7_dp_pattern, seg7_pattern};` 是一次盲拼接。`seg7_pattern[6:0]` 是 `{a,b,c,d,e,f,g}`(seg7_pattern[6]=a ... seg7_pattern[0]=g,seg7_decoder.v 自己头部注释里写明的约定),拼接结果是 `dig[7]=dp, dig[6]=a, dig[5]=b, dig[4]=c, dig[3]=d, dig[2]=e, dig[1]=f, dig[0]=g`。但手册确认的物理映射是 `DIG[0]=a, DIG[1]=b, DIG[2]=c, DIG[3]=d, DIG[4]=e, DIG[5]=f, DIG[6]=g, DIG[7]=dp`——dp 恰好落对了位置(bit7),但 a..g 这7位的顺序整体反了(应该 a 在 bit0,却被摆到了 bit6;应该 g 在 bit6,却被摆到了 bit0)。跟这个项目之前 EAN-13 `leading_digit` 反推表位序搞反、BNN权重位序踩坑是同一类错误——这次是笔者自己在写这行拼接代码时犯的,不是转录第三方资料出的错。

**已修复**:把这行盲拼接换成8行逐位显式 `assign`(`assign dig[0] = seg7_pattern[6]; // a` 一直到 `assign dig[7] = seg7_dp_pattern; // dp`),每行都标注对应的段字母,不再依赖拼接顺序,以后不会再无声反转。改动只在 `camera_display_top.v` 里(560行附近),`seg7_decoder.v`/qsf 引脚分配都不用动——引脚分配本来就是对的,错的只是驱动 `dig` 这几行 RTL 的位序。

验证:改完后依然遇到一次 bash 挂载读回截断(camera_display_top.v 显示570行、卡在注释中间,而 Read 工具读到的真实内容是598行完整文件)——按已有流程用 Read 工具内容整体 heredoc 重写、重新校验(连续3次 wc -l/md5sum 一致)、并额外跑了 `iverilog -tnull camera_display_top.v` 单文件编译确认干净(0 syntax error,只有该文件自身依赖的模块因为没一起传入报"unknown module",这是预期的)。再把 `camera_display_top.v` 和全部相关子模块(不含仿真专用的 testbench 和其它测试顶层)一起联合编译,除了已知且跟本次改动无关的 `altpll`(my_pll.v)/`dcfifo`(pixel_fifo.v)两个 Quartus 专用宏功能报"unknown module type"外,无任何新增报错——`dig` 位序修复本身没有引入语法或连线问题。**用户还没编译烧录验证**,如果这次数码管显示的字形变成正常数字了就是确认修复生效;如果字形依然不对或者变成另一种错误图案,下一步该查的是 `seg7_decoder.v` 内部 case 表本身(0-9每个字形的段位组合)是否也有类似的位序问题——但这部分已经有独立仿真验证过,可能性较低。

## 芯片资源(已核实)
- EP4CE10:10,320 LE = 645 LAB(16 LE/LAB),46 个 M9K(共约424Kbit 片上RAM),**15个18×18硬件乘法器**(之前误以为没有硬乘法器,已用 Intel 官方规格核实纠正)。当前流水线(模糊/Sobel/NMS/质心追踪+卡尔曼/EAN-13)全程没用过一次乘法器,都是移位加法(EAN-13 的×3/×5/×7 也是移位加法拼的,mod10 是有界循环减法)——15个乘法器是真正的富余量,以后如果做 Harris 角点检测这类需要真乘法的功能可以用。

## 关键架构决定
- 传感器输出 **YUV422(YUYV)**,不是 RGB565:8位亮度消除了 RGB565 的同心圆色带。0x4300=0x30, 0x501f=0x00
- LCD 侧 `yuv422_to_rgb888.v` 做 BT.601 定点转换,1像素延迟
- **LCD 三通道数据总线位序需反转**(板上接线相对 qsf 编号是 MSB-first),已在 camera_display_top 和 lcd_pattern_top 里用 generate 反转。彩条测不出位序错,渐变才能
- PLL(my_pll.v,手写 altpll):c0=100M, c1=24M(XCLK), c2=8.955M(LCD,精确9M与100/24共VCO不可实现,VCO=600M), c3=100M/-75°(=7917ps)给 SDRAM 芯片
- SDRAM(W9825G6KH-6,板载丝印;手册写 HY57V2562GTR,引脚兼容):sdram_ctrl.v 突发4、CL2@100M,bank[0]=乒乓缓冲位,自测双 buffer 全通过。容量256Mbit,现有乒乓缓冲只用了约4.18Mbit(不到2%),有大量冗余空间,但受限于单端口物理总线(单套地址/数据/命令线),真正的瓶颈是"同一时刻只能服务一个客户端"的总线仲裁问题,不是容量
- dvp_capture:数据打拍与 href 对齐;字节序 {第一字节,第二字节}
- 帧缓冲:pixel_fifo(dcfifo 16b×512 show-ahead)×2 + frame_buffer.v 乒乓调度,CDC 用 toggle+同步器

## SD 卡(暂停,等换卡)
- sd_spi.v / sd_ctrl.v / sd_test_top.v / sd_dump.py 已就绪,协议实现达到 FatFs 等级:真CRC、每命令CS翻转+等就绪、轮询间隔、ACMD41→CMD1 降级
- **联想 16GB TF 卡 SPI 模式固件不完整**:只应答 CMD0/CMD8,CMD55/CMD1 全部沉默(判别实验:第二次 CMD8 在同位置正常 → 非引擎问题)。Windows 读卡器正常(走 SD 模式)
- 结论:需换闪迪/金士顿/三星正品 SDHC 8-32GB。现有固件对正常卡应可直接工作
- LED 错误码表在 sd_ctrl.v 注释;SD_DEBUG_REVIEW.md 有完整调试记录
- 用户最终目的:存单帧原始图到卡→PC对比(已用 lcd_pattern_top 的受控图案实验替代完成:屏无罪,色带=565量化)

## 踩坑记录(重要)
- **qsf/camera_display_top.v/AGENTS.md 常在写入后被截断**:反复出现的问题——用 Write/Edit 工具确认写入成功、用 Read 工具读回也显示内容正确,但过一会儿用 bash 读挂载路径下的同一个文件,内容会在某个中间位置突然截断,或者干脆是完全没编辑过的旧版本。这不是猜测,已经在 sobel_edge.v / nms_thresh.v / tb_sobel_edge.v / tb_nms_thresh.v / tb_integration_nms.v / camera_display_top.v / CameraCapture.qsf / AGENTS.md / tb_barcode_decoder.v / ean13_decoder.v / bnn_core.v / bnn_demo_top.v / tb_bnn_demo_top.v / roi_binarize_28x28.v / tb_roi_binarize_28x28.v / ov5640_reg_table.v / CameraCapture.v 上都真实发生过,其中 CameraCapture.qsf 和 AGENTS.md 各自发生了不止两次(累计已经四五次以上)。**固定的修复流程**:每次大改动 Write/Edit 后,必须立刻用 bash 读回校验(字节数、空字节数、utf-8/ascii 可解码性、文件尾部是否是预期结尾如 `endmodule`);一旦发现异常,不要用 Edit 小修小补,用 Read 工具重新读一次真实内容,整个通过 heredoc 或 Python 脚本强制整体重写一遍,重写后再校验一次,必要时重复2-3轮才能稳定。
- **"连续多次校验一致"不等于"内容正确"**(2026-07-17新教训):曾经在校验流程里认为"连续3-4次 bash 读回,字节数/md5都一致"就说明状态稳定可以继续——这次发现一个反例:camera_display_top.v 被截断后,连续4轮校验全部稳定复现同一个**截断的**版本,一致性检查完全没能发现问题。真正靠谱的验证是额外跑一次 `iverilog -tnull single_file.v` 语法编译检查,编译干净才算数,不能只看多次读取是否互相一致。
- **iverilog 多文件联合编译时,一个文件的真实语法错误会级联污染报错信息里其它文件的归属**:排在前面的文件(如 camera_display_top.v)出现截断/语法错误后,解析器带着错误状态继续解析后面传入的文件列表,导致报错行号/文件名指向了实际完全没问题的后续文件(比如联合编译报 CameraCapture.v/roi_binarize_28x28.v 一堆 syntax error,单独编译这两个文件却是干净的)。**排查时应该先对每个可疑文件单独跑 `iverilog -tnull xxx.v`,不要直接相信联合编译报错信息里给出的文件名**。
- F16(sdram_cke)是 nCEO 双功能脚:需 `CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION "USE AS REGULAR IO"`
- E15 是时钟专用输入,不支持 weak pullup assignment
- 全局 IO 标准:`STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"`(默认2.5V会和 LCD 3.3V 冲突;-entity 作用域的 IO assignment 换顶层就失效)
- SignalTap:换顶层前必须 ENABLE_SIGNALTAP OFF,否则旧探点报错;探点用 pre-synthesis 名,别选 ~feeder;存储限定(Input port=字节done)可实现每字节一采样;触发要"先 Run 再按复位"
- SD 卡换卡必须断电插拔(卡内部状态只有断电能清);wmic 已从新 Win11 移除,用 Get-Disk
- ov5640_init 在软复位(0x3008=0x82)后有 10ms 延时状态(必需)
- sccb/sd 的 spi_start 类握手:busy 延迟两拍,发送分支必须 `!busy && !start` 双守卫防连发
- **Verilog `reg` 数组 + `initial` 块驱动的"测试ROM",仿真里没问题不代表真实综合/烧录里可靠**:bnn_demo_top.v 的教训——`initial` 块能不能被 Quartus 忠实转换成硬件上电初始值不是100%保证的,尤其是标准做法都是用 `localparam`(纯组合逻辑常量,烧录进配置比特流里跟别的逻辑一样可靠)而不是"reg数组+initial"表示"这是一份固定不变的数据"。以后凡是"写死的测试数据/查找表",优先用 `localparam` + `case`/函数选择,不要用 `reg`+`initial`,除非明确知道综合工具支持且已经真机验证过

## 摄像头画质寄存器(已调)
- AEC 目标:0x3a0f=38/3a10=30/3a1b=38/3a1e=30/3a11=70/3a1f=18
- 饱和度:0x5584=0x40(原0x10导致发灰)
- 0x5000=0xa7(LENC+gamma+BPC/WPC)
- 镜像:0x3821=0x07(水平镜像开,用于抵消摄像头模组物理安装朝向导致的原始画面镜像——用户反馈LCD图像是镜像的,原0x01是"关"。**未实测确认方向是否真的修正对了**,烧录后需要肉眼看文字/手写朝向是否正常,不对就改回0x01)
- 镜头为手动对焦,画质问题先转镜头

## 引脚(qsf 已全部配置)
摄像头:SIO_C=F1,SIO_D=F3,PCLK=G1,VSYNC=F2,HREF=K1,XCLK=K2,D[7:0]=J2,J1,N5,L1,M1,G2,M6,L2,RESET=N6,PWDN=M7
LCD:R=R10~T14,G=R6~T10,B=P3~T6,DCLK=T2,HS=M9,VS=L10,DE=L9(注意位序反转在RTL做)
SDRAM:CLK=B14,CKE=F16,CS=K10,WE=J13,CAS=J12,RAS=K11,DQM=J14/G15,BA=G11/F13,A0-12=F11,E11,D14,C14,A14,A15,B16,C15,C16,D15,F14,D16,F15,DQ0-15=P14,M12,N14,L12,L13,L14,L11,K12,G16,J11,J16,J15,K16,K15,L16,L15
SD:NCS=D11,CLK=D12,DIN(MOSI)=F10,DOUT(MISO)=E15
LED:E10,F9,C9,D9;CLK=E1;RST=N13(板上共8个LED,本工程只驱动4个,其余悬空微亮属正常)
KEY(按下=0,来自AX4010手册Part13):KEY1=M15,KEY2=M16,KEY3=E16(注:M15 与旧测试信号 key_start 共用,key_start属于已弃用的 sccb_top_test,非当前 TOP_LEVEL_ENTITY,不冲突)
数码管(AX4010板载6位,共阳极低电平点亮,手册p.31已确认):DIG[7:0]={dp,g,f,e,d,c,b,a}=R14,N16,P16,T15,P15,N12,N15,R16;SEL[5:0](每位使能,极性未确认,假设低有效)=N9,P9,M10,N11,P11,M11。只驱动sel[0](最右一位)显示BNN分类结果,其余5位常态不选中

## 后续可选方向
1. 换卡后:拍照模式(冻结一帧510块写SD,sd_dump.py --frame 转PNG)
2. OV5640 JPEG 模式全分辨率静态照(证明500W传感器能力)
3. CMD25 多块连写提升SD吞吐
4. 颜色阈值调参脚本(照 edge_threshold_tuner.py 思路,用电脑摄像头实时调 color_blob_tracker.v 的 R_LO..B_HI 六个阈值)
5. 运动检测(motion_detector.v/motion_overlay.v)如果以后想要,文件还在,qsf 取消注释、顶层重新实例化即可复用
6. 条码识别数字文本渲染:ean13_decoder.v 的 decoded_digits(13个4bit数字)已经是可用的端口输出,还没接到屏幕上显示,可以做一个简单的数字字形叠加模块,或者先用 SignalTap 看
7. ean13_decoder.v 的模块宽度估计目前只在起始哨兵那一刻算一次,如果实测发现条码有透视变形导致中途解码失败,可以考虑在中间哨兵处也重新校准一次 X_est(需要额外一次三段接近检测,逻辑上跟起始哨兵检测是同一套,复制一份状态机分支即可)
8. BNN子项目已在真机上验证成功,摄像头→CNN→AX4010板载数码管整条链路代码已写完接入、引脚已按手册p.31全部配好,**用户已编译烧录并测试,反馈三个问题已全部修复(见上方"用户编译烧录后测试反馈三个问题"一节)**:空白帧误显示数字(加ink_count阈值判断)、镜像影响识别(0x3821打开水平镜像补偿)、缺少ROI取景提示(加了绿色边框叠加层)。**用户测试这一轮修复后又反馈第四个问题("digital tube显示的为什么不全是数字"),已定位并修复:`dig` 拼接位序反了,见上方"digital tube 段位顺序bug已修复"一节**。用户确认过"单个位但图形不像数字"这个症状(SEL选中本身正常,只是段位组合错),跟位序反转的根因吻合。**用户还没编译验证这一轮(含新的段位序修复)**。下一步需要:(a)编译烧录后确认数码管这次能不能显示出正确数字字形;(b)确认无墨迹时数码管正确熄灭、LCD画面朝向是否变正常、绿框位置是否跟实际ROI对齐;(c)如果镜像方向改反了,0x3821两处都要改回0x01;(d)数码管SEL极性假设(低有效)目前看大概率是对的(用户反馈只有一个位点亮,不是完全不亮或点亮错误位置),但仍未被用户明确确认,如仍有问题可改SEL_ACTIVE_LOW;(e)编译一次拿真实LE/LAB数字,确认能不能跟主流程共存;(f)镜头对焦问题仍待解决;(g)THRESH/ROI尺寸/MIN_INK_PIXELS等参数大概率需要拿真实手写数字实测调参

## Imported Claude Cowork project instructions

Be clear and beginner friendly.
