# AutoFollow Taxi —— RL 系统设计总结

> 本文档侧重**模型结构、构建方式、工作流程**，面向论文的"系统设计"与"实验"两节。
> 使用方式、日常命令与踩坑纪律见 `rl/README.md`；每次实验的记录见 `rl/logs/RUNS.md`。

---

## 一、系统分层

```
┌─ Godot 4.7.1（车辆物理与业务仿真）──────────────────────────────┐
│  MMT 模块化车辆（发动机/齿箱/轮胎/转向/差速器/TCS…）            │
│  TaxiServiceComponent：接客/送达状态机（判定半径与停稳阈值）      │
│  PassengerManager：乘客对象池、生成点、目的地分配、抢客认领       │
│  AITaxiController：一个 RL agent 的全部胶水                      │
│    ├ 动作 → MMTVehicleInputState（throttle/steer/reverse）      │
│    ├ 观测 = 自车状态 + 射线 + 相对位置                          │
│    ├ 奖励 = RewardManager 汇总所有 RewardFunction3D 子节点       │
│    └ 指标 = get_info()（接送事件，读后清零）                     │
│  TaxiSync（extends Sync,godot_rl 插件）                         │
│    ├ 每 action_repeat 帧收发一次：obs / action / reward / done   │
│    ├ Engine.time_scale = speed_up（物理加速）                    │
│    └ 参数来自 OS.get_cmdline_args()（无头模式）                  │
└────────────────────────── TCP JSON :11008 ─────────────────────┘
┌─ Python（godot_rl 0.8.0 + Stable-Baselines3 2.9）──────────────┐
│  StableBaselinesGodotEnv → VecMonitor → PPO(MultiInputPolicy)   │
│  CombinedExtractor（自定义分塔特征提取器）                       │
│  MetricsCallback（task/* 业务指标）                              │
│  信息透传补丁（修正上游丢 info 的 bug）                          │
└────────────────────────────────────────────────────────────────┘
```

**两种运行模式**（互斥）：

| 模式 | 启动 | 环境数 |
|---|---|---|
| 编辑器内 | 先起 Python（`env_path=None`），再在 Godot 里 Play | 单实例 |
| 无头并行 | `--env_path Export/xxx.exe --n_parallel N` | N 个进程 |

⚠️ 编辑器内训练时，Godot 只读**游戏进程自己的**命令行，Python 侧的 `--speedup / --action_repeat` 不会转发进去；这类参数必须改场景里 Sync 节点的导出值。

---

## 二、观测与动作契约

### 观测 `Dict{"obs": Box(-1, 1, (419,))}`

| 区间 | 内容 | 维度 | 说明 |
|---|---|---|---|
| `[0, 8)` | 自车状态 | 8 | 回合进度、前向速度、横向速度、横摆角速度、转向角、转速、挡位、是否着地 |
| `[8, 392)` | 射线 | 384 | 4 方向 ×(远 6×3 + 近 10×3)×(距离, 类别) |
| `[392, 419)` | 相对位置 | 27 | 目标 3 维（`to_local`，截断 8 m）+ 6 个对手 ×4 维 |

**没有任何绝对坐标或场地标识** —— 策略只看到*局部几何*。这是刻意的：它保证了"策略必须学一套对局部几何条件化的行为"，而不是记住"我在哪张地图"。这也是后续泛化讨论的出发点。

**感知范围**（决定泛化上限）：远射线 7 m、近射线 3 m、目标向量截断 8 m。超出这个半径的布局**不可观测**。

### 动作 `Box(-1, 1, (3,))`

按 `AITaxiController.get_action_space()` 的声明顺序：

| 索引 | 名称 | 语义 |
|---|---|---|
| 0 | `throttle` | 取绝对值当油门大小 |
| 1 | `steering` | 转向轴 |
| 2 | `reverse` | `> 0` 表示想倒车，与油门大小正交 |

**没有 brake 通道**：刹车由车上的 `auto_hold` / `auto_reverse` 自动完成。早期版本把 brake 暴露给策略，结果随机 brake 值（扭矩上限 1200 Nm）足以完全抵消发动机输出（≈143 Nm），策略学到的最优解是"别动" ✗ —— 这是动作空间设计的第一条教训。

**动作先验**（只在新建模型时生效）：

- `--log_std_init -1.0`：初始探索尺度 σ≈0.37（SB3 默认 0 → σ=1.0，等于开局方向盘打满）；
- `--action_bias "0,0,-0.5"`：倒车通道初始均值 -0.5 ⟹ P(倒车) 从 49% 降到 ~9%（实测 2000 次采样）；
- `--reset_log_std`：**续训时**把已塌缩的 σ 重新拉大（见第六节）。

---

## 三、策略网络

**算法**：PPO（SB3 2.9）`MultiInputPolicy`（实际类 `MultiInputActorCriticPolicy`）。

**为什么不用默认 MLP**：419 维扁平向量里三块语义完全不同 —— 射线占 62% 且极稀疏（大多为 0），直接喂 `[256,256]` MLP 会让首层梯度被射线主导，学成"只会避障"。

**`CombinedExtractor`（分塔编码）**：

```
self     (8)   → Linear(128) → LayerNorm → ReLU → Linear(128) → ReLU ┐
raycast  (384) → 共享 Conv1d 塔（见下）                          ├→ concat(384) → PPO 的 mlp_extractor [256,256]
position (27)  → Linear(128) → LayerNorm → ReLU → Linear(128) → ReLU ┘
```

射线塔的**方位角等变性**做法：

1. 每个方向 96 维 reshape 成 `(方位角, 仰角×值=6)`，转置后沿**方位角**做 1D 卷积 → 通道 = 6，长度 = 方位角；
2. far（方位 6 列）与 near（方位 10 列）**共用同一套卷积权重**（这是等变性的载体）；
3. 池化用固定 kernel 的 `MaxPool1d`，**不能用 AdaptiveAvgPool**（后者在 ONNX 追踪时长度是符号 `*`，导出直接失败）；用 Max 因为射线大多未命中（0.0），Avg 会稀释命中；
4. 共享卷积丢掉的**方向/尺度身份**用一个 `emb[n_scales, n_dirs, per_block]` 加回来；
5. 4 方向 × 2 尺度 = 8 个块，各块输出拼接后 `LayerNorm`。

输出 = 3 × 128 = 384（不膨胀），交给 PPO 的 `net_arch=[256,256]`。

**ONNX 导出契约**（`train.py: export_onnx`）：输入 `obs`（按 key 排序的扁平张量列表）+ `state_ins`，输出 `output`（动作均值）+ `state_outs`（透传）。用 `dynamo=False` 的 TorchScript 导出器（dynamo 需要 onnxscript，旧导出器不接受 dict 观测）。**导出后用 onnxruntime 跑 5 组随机观测与 SB3 逐元素比对（阈值 1e-5）** —— "导出成功"和"导出正确"是两件事。

---

## 四、奖励系统

### 组合方式

`RewardManager`（每辆车一个）收集其下所有 `RewardFunction3D` 子节点，**每物理帧**调用一次 `get_reward()` 并求和。每个奖励项有独立的 `enabled` 开关（由 `AIParameterEntry` 按**类名限定**下发）。

### 各项

| 奖励项 | 作用 | 关键参数 |
|---|---|---|
| `PickUpAndDropRewardFunction` | 主任务：接/送事件 + 进度塑形 + 减速引导 + 横向滑移惩罚 | `reward_pickup=2`、`reward_dropoff=5`、`rw_progress=3.0`、`rw_step=-0.008/env step`、`rw_speed`、`target_follow_distance` |
| `DenseNavigationReward` | Phase 1 纯导航（隔离变量、验证学习链路） | `rw_progress=3.0`、`rw_step=-0.01/帧` |
| `SteeringSmoothnessReward` | 惩罚转向抖动：`-w·|Δ转向比|`，匀速转弯免费 | `weight=0.2` |
| `WallContactReward` | 撞墙：接触期间**每帧**扣分，按物理层只统计墙 | `weight=0.02`、`weight_impact=0`（可选升沿项） |
| `isMovingRewardFunction` | 低速惩罚（**全程禁用**，见教训） | `max_step_penalty=0.5` ← 危险默认值 |

### 进度塑形：势函数形式

`r += rw_progress × (d_prev − d) / d_0`，`d_0 = max(锁定目标时的距离, track_range)`

- 差分会伸缩求和 ⟹ **每段子目标的塑形预算恒为 `rw_progress`**，与地图尺度无关；
- 它是 potential-based shaping，**不改变最优策略**，只提供密集梯度；
- 副作用（重要）：**"远离目标"在塑形上是负分**，所以绕路/倒车需要先穿过一段负奖励谷 —— 这是"学不会倒车/绕路"的奖励侧原因之一。

### 参数下发机制（易错点）

Arena 场景里挂 `AIParameter` 节点，其 `AIParameterEntry` 数组按 `company_id` 匹配阵营；`VehicleSpawnManager._spawn_one()` 在**生成车辆时**把字段按**同名匹配**写到车辆子树的所有 AI 节点上。两个必须遵守的约束：

1. **只在生成时下发** ⟹ 训练跑着的时候改场景不生效；
2. **别名必须带类名限定** ⟹ 三个 `enabled_xxx` 字段若都只映射到 `enabled`，会按声明顺序互相覆盖，导致"面板里关了、运行时还开着"（真实踩过）。

---

## 五、回合与步的定义

| 量 | 值 | 来源 |
|---|---|---|
| 每个 env step | `action_repeat = 8` 个物理帧 | `sync.gd` |
| 物理帧步长 | `time_scale/ticks = 4/240 = 1/60 s` | `speed_up=4` + `project.godot: physics_ticks_per_second=240` |
| 回合上限 | `reset_after = 10800` 帧 = **1350 步** = 180 s 仿真时间 | `AITaxiController` |
| 终止 | 送达成功（`enable_success_terminal`）或超时（`reward_fail = -6`） | 同上 |
| 观测里的回合进度 | `n_steps / 10800` | `get_obs()` |

**交叉验证**：`ep_len_mean` 在平地上实测 `1351`、成功率 100% 后降到 `73~94` —— 与 `10800/8 = 1350` 精确吻合，说明步/帧/时间三者的换算是对的。

⚠️ **时间尺度陷阱**：`speed_up` 写的是 `Engine.time_scale`，Godot 用它乘**物理帧的 delta**（不是乘帧数）。默认 60Hz 时每个物理帧推进 `4/60 = 66.7 ms`，比设计粗 4 倍（转向速率限制、轮胎力、Jolt 全按这个步长积分）。把 `physics_ticks_per_second` 设成 240 后 delta 恰好回到 `1/60 s`，4 倍实时速度不变。**实测验证**：修正后同一权重下转向抖动惩罚降到 1/4。

---

## 六、训练工作流

### 命令

```bash
# 新建训练
uv run python train.py --timesteps 2000000 --experiment_name StageN --experiment_dir logs

# 续训（读同一个文件、写同一个文件，自链式累积）
uv run python train.py --timesteps 5000000 --experiment_name StageN+1 --experiment_dir logs \
  --resume_model_path logs/StageN_final.zip

# 探索重启（策略收敛到局部最优、σ 已塌缩时）
uv run python train.py --timesteps 2000000 --experiment_name StageN_r --experiment_dir logs \
  --resume_model_path logs/StageN_final.zip --reset_log_std -1.0 --ent_coef 0.01

# 评估（确定性动作，不训练）
uv run python evaluate.py --model logs/StageN_final.zip --episodes 30

# 无头并行
uv run python train.py --env_path ../Export/xxx.exe --n_parallel 2 --timesteps 2000000 ...
```

### PPO 超参（默认）

`n_steps=2048`（每 env）、`batch_size=256`、`n_epochs=10`、`γ=0.99`、`GAE λ=0.95`、`clip=0.2`、`lr=3e-4`、`vf_coef=0.5`、`max_grad_norm=0.5`、`ent_coef=0.001`（恢复探索时用 0.01）、`net_arch=[256,256]`、`features_dim=128`。

### 课程（离线人工切换，Python 侧不认识"阶段"）

| 阶段 | 场景 | 关键配置 | 结果 |
|---|---|---|---|
| Phase 1 | 平地 | `enabled_dense_nav=true`，其余关 | 验证学习链路 |
| Stage2 | 平地 | `enabled_pickdrop=true`，宽松判据 5/10/5 | **成功率 1.00**，回合 94 |
| Stage3 | 平地 | **收紧判据**（3/4/2.5） | **成功率 1.00**，回合 **73**，送达 1325 |
| Stage4→5 | 有墙（单布局） | 加 `WallContactReward` | **96.5%** |
| Stage6 | 6 变体混合 | 每次只改一个因素 | **~0.44→0.60**（泛化差距） |
| Multi_0 | 4 arena × 4 车（2 阵营） | `--n_parallel 2` ⟹ 32 agent，默认严格判据 2/2.5/1.5 | **10.5%**，接客 398 / 送达 92 / **被抢 254** |

### 保存与续训

- 运行结束**必定**写 `<experiment_dir>/<name>_final.zip`；`--save_checkpoint_frequency` 默认 20 万步；
- `PPO.load` 会一并恢复策略/超参（LR 以常数存盘，续训不会卡在衰减尾部）；
- **续训会把 `log_std` 的塌缩一起带过来** ⟹ 必须用 `--reset_log_std` 才能重新探索（实测 `[0.276, 0.042, 0.316] → [0.368, 0.368, 0.368]`）。

---

## 七、指标体系（三层）

| 层 | 内容 | 用途 |
|---|---|---|
| TensorBoard `rollout/*` | `ep_rew_mean`、`ep_len_mean` | 只看趋势；会被塑形项污染 |
| TensorBoard `task/*` | `pickups`、`dropoffs`、`success_rate`、`episode_reward`、`episode_length`、`stolen` | **唯一可信的业务指标**（来自 `AITaxiController.get_info()`，经 `MetricsCallback` 聚合） |
| 控制台 `[Reward]` 行 | 各奖励项的**每帧**均值、禁用列表、**运行时生效的接送容差**、相位、`d`、`v`、**倒车指令占比**、**场地名**、场地乘客池 | 逐车逐场地的状态诊断 |

**回合回报速算**（拿来交叉验证）：成功送达 ≈ `12 − rw_step × 步数`；超时 ≈ `rw_step × 1350`。
例：回合 98 的成功回合 ≈ +11.2，TB 实测 +11.1 ✓。

---

## 八、工程教训（方法论贡献）

每一条都有实测数字支撑，建议在论文中作为"可复现的失败模式"列出：

1. **假指标**：`godot_rl 0.8.0` 的 `step_recv()` 把每步 info 丢成 `[{}]*n`，而 Godot 侧 `get_info()` 是读后清零 ⟹ `task/pickups/dropoffs/success_rate` **结构性恒为 0**。车已真的接到客（换牌照 + `has_passenger=true`），指标却一直是 0。修法：在**自己的代码里**打补丁（不改 site-packages）。教训：**先验证指标，再拿它做判断**。
2. **探索塌缩**：`log_std` 单调衰减到 `[0.276, **0.042**, 0.316]`（转向维度几乎确定性）。`--reset_log_std -1.0` + `--ent_coef 0.01` 把 σ 拉回 0.368 ⟹ 成功率 `0 → 1.00`。**这是本项目最干净的一组对照实验。**
3. **钳位惩罚的陷阱**：`isMovingRewardFunction` 的 `max_step_penalty=0.5` 被顶满 ⟹ 占奖励合计 99.8%（≈ **−5246/回合**）。更致命的是**钳位后梯度为 0**：批评家只吸收一个常数，真正的信号（~0.01 量级）被淹没 50 倍。表现是"Agent 完全不想倒车"——真相是"它听不见叫它倒车的声音"。
4. **观测函数不能有副作用**：位置传感器的兜底路径调了会写认领表的 `assign_passenger` ⟹ 观测把乘客认领掉、业务层 `acquire_target()` 永远拿不到它 ⟹ 约 1/6 的 arena 整局无目标、梯度恒为 0。修法：拆出只读的 `peek_*`。
5. **惩罚的形状**：逐帧"在场税"（贴着就扣、静止也扣）能让"离开墙"有利可图；而"撞击"这类**事件型**惩罚可以被"慢慢撞"满足，且对"卡住不动"没有持续梯度。两者只能叠加，不能替换。
6. **动作序列的可探索性**：倒出 3~5 m 需要连续约 20 个 env step 的倒车，而单步采样概率 ~8% ⟹ 连续 20 步 `0.08²⁰ ≈ 0`，**随机探索在数学上产生不了这个序列**。修法：**倒车挡位保持**（一次采样 = 一段持续倒车），把所需探索从"连续 20 次"降到"1 次"。
7. **环境侧课程优先于奖励调参**：一堵 20 m 宽、20 m 高的墙横在唯一走廊上时，势函数塑形只会指"直线距离变小"，绕过去要先走反方向（负奖励）——**那是迷宫，不是避障**。留出 8~10 m 通道后立刻学会绕行。**探索问题最好在环境侧解决。**
8. **感知范围决定泛化边界**：远射线仅 7 m ⟹ 超出视野的布局不可判 ⟹ 6 变体混合下成功率从单布局的 **96.5% 掉到 ~44%**（后回升至 ~60%）。部分可观测下，策略只能学"平均最优的对冲"。
9. **冻结均衡**：逐帧接触税（0.02/帧）在墙多的场景里把"移动"本身变得不划算 —— 实测六辆车同时停在空地（`v≈0`、`WallContact≈0`、离目标 12~36 m）。三种结局的每回合回报：**停车 ≈ −23、冲进去被顶 ≈ −142、停准送达 ≈ +10**。策略正确地在"停车/被顶"之间选了停车。**逐帧惩罚是双刃剑：它能教会"离开墙"，也能教会"根本不靠近"。**
10. **超参的两个隐性陷阱**：`--linear_lr_schedule` + 长 run 会让 lr 退到 1.7% 初始值，后段**实际停止学习**（曲线因此又平又稳，容易被误读为"收敛良好"）；`--speedup` 默认值会覆盖场景的 `speed_up`，使评估与训练的**物理步长不一致**。

---

## 九、已知边界（论文的 Limitations 一节）

1. **部分可观测**：7 m 感知半径决定了长程布局不可判，多布局泛化存在上界（实测 ~44%→60%）；
2. **判据口径**：`success_rate` 离开判据没有意义 —— 宽松判据（接 5/送 10/停 5）下达 100%，严格判据（接 2/送 2.5/停 1.5）下"同一算法"只有 10.5%。**任何成功率都必须连同判据、阵营数、agent 数一起报**；
3. **竞争场景的奖励缺口**：`stolen_penalty` 为 0，奖励里对"被对手抢走目标"没有任何信号（254 次抢客事件在奖励上是不可见的）；
4. **单帧前馈策略**：没有记忆，无法利用"一路走过来看到的信息"推断布局；若要突破第 1 条，方向是帧堆叠/循环策略或更长射线；
5. **同质 agent**：所有车共享同一套策略（参数共享），没有角色分化，也没有显式的协作/通信机制。
