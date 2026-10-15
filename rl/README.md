# AutoFollow · RL（PPO + godot_rl）

## 一、怎么跑（两种模式，别混用）

### A. 编辑器内训练（当前在用）
1. 在 `rl/` 起 Python（它会等待连接）：
   `uv run python train.py --experiment_dir logs --experiment_name <名字> [--timesteps N]`
2. 在 Godot 里 Play `levels/ParaFlatTrainScene.tscn`。
   （两个顺序都能连上，`sync.gd` 会重试；先起 Python 更稳。）

⚠️ 这个模式下 Godot 的参数来自**游戏进程自己的命令行**（`sync.gd:_get_args()` 读
`OS.get_cmdline_args()`），编辑器 Play 默认不转发 Python 的命令行 —— 除非在编辑器
设置里配了「主运行参数」。所以 `--speedup` / `--action_repeat` / `--framerate`
**改场景里 Sync 节点的导出值是唯一可靠的办法**。

### B. 无头并行
先导出，再 `--env_path ../Export/Train.console.exe --n_parallel N`。
导出物是**打包快照**：改了脚本/场景必须重新导出，否则跑的是旧代码
（用 `Select-String` 在 `.pck` 里找一个新字符串就能确认）。

## 二、看什么指标

- `task/pickups` / `task/dropoffs`：**唯一可信**的业务指标。
- `rollout/ep_rew_mean` 会被塑形项污染，只能看趋势，不能看绝对值。
- **回合回报的速算公式**（拿来交叉验证，实测对得上）：
  `return ≈ 12 − rw_step × 步数`（成功送达时；12 = 接客 2 + 送达 5 + 终端 5）
  例：`ep_len 98` 的成功回合 ≈ +11.2，TB 里 `ep_rew_mean = +11.1` ✓。
  超时未送达 ≈ `rw_step × 1350`（≈ −10.8）。混合成功率时按比例加权即可估算。
  **推论**：回合越短回报越高，但**不是因为"短"有奖励**，而是因为
  ①`rw_step` 是每步线性代价；②送达会拿终端奖励并立刻结束回合，后面的时间代价全免。
  真正驱动"快"的只有 `rw_step` —— 进度塑形是势函数，快慢走完同一段总收益相同。
- 控制台 `[Reward]` 行（`RewardManager.debug_breakdown = true`）：每
  `debug_interval` 个物理帧打印各奖励项的**每帧**平均值 + `禁用:[...]`。
  奖励相关问题永远先看这一行，别靠读代码猜。

## 三、改动纪律（都是踩过的坑换来的）

1. **动车辆物理 / 传动 / 参数（齿箱、变矩器、轮胎、转向、质量、悬挂）之前，
   先让真人用玩家车开一圈。** AI 训练日志看不出「起步肉不肉」「换挡顺不顺」，
   这类改动在 AI 侧只表现为「学得慢」，会把人骗到奖励/网络那边去找错。
   - 现存案例：给 `MMTGearboxComponentTEMP` 加变矩器时，传递扭矩多乘了一个
     `_current_tc_coupling`（失速时 ≈0）→ 起步扭矩 ≈0 → 「油门踩到底车不走」。
     训练侧只看到进度奖励变小，像奖励设计问题；玩家一上手立刻能定位到传动。
   - 这些组件是**玩家车与 AI 车共用**的（`mmt_sedan.tscn` 与
     `mmt_ai_sedan.tscn` 都 `use_fluid_coupling = true`），改一处两边都变。

2. **场景 / `project.godot` 改完必须重启编辑器**，再核对日志确认生效。
   拿改动前的旧进程输出下结论，等于白改（`physics_ticks_per_second` 踩过一次）。

3. **训练跑着的时候改 `.tscn` 不会生效**：`AIParameterEntry` 是在
   `VehicleSpawnManager._spawn_one()` 里**生成车辆时**下发的，已经生成的车不会被改。

4. **`AIParameterEntry.apply_to()` 按「同名字段 + 目标脚本类名」写入。**
   新增「按奖励函数分别开关」的字段时，必须同时在 `FIELD_ALIASES` 里补
   `{"field": ..., "class": ...}`；只写同名字段会让多个 `enabled_*` 互相覆盖
   （详见该文件里的注释）。

5. **改动作空间 / 观测布局后旧模型全部作废**，必须从头训练
   （见 `train.py` 的 `export_onnx` 契约说明）。

6. **指标本身要先验证，别拿一个恒为 0 的数做判断。** 实测踩过：`godot_rl 0.8.0`
   的 `GodotEnv.step_recv()` 把每步的 info 丢成 `[{}] * n`（`godot_env.py:209`），
   而 Godot 侧 `sync.gd:222` 是发 info 的、`AITaxiController.get_info()` 又是**读后清零**
   —— 于是 `task/pickups / dropoffs / stolen` **结构性恒为 0**。车已经真的接到客
   （车顶牌照都换了、远程检视器里 `has_passenger = true`），指标还是 0，
   害得连续几轮都在分析一个假 0。
   修法：`rl/train.py` 里的 `_patch_godot_env_info()`（放在我们自己的代码里，pip 重装不丢）。
   - 仍然可信的：`ep_len_mean`（走 `done` 链路）、`rollout/ep_rew_mean`。
   - 判断"某个指标是不是真的在动"的最快办法：改一处**必然**会触发它的地方，看它动不动。

7. **"查询"和"认领"必须分开：观测函数绝不能有副作用。** 实测踩过：
   `PassengerDistributeManager.pick_best_target_for()` 会写认领表
   （`_reservations[乘客][公司] = true`，而 `cooperative_within_fleet` 默认 true、
   **没有任何场景覆盖它**），而同公司被认领过的乘客会被**永久跳过**。
   传感器 `PassengerPositionSensor3D` 的兜底路径原来调的就是这条会写的接口，于是：
   ```
   ① 传感器问一次 → 认领表记下 (乘客P, 公司0) → 返回 P（那一帧画线，看着正常）
   ② 业务层 acquire_target() 再问 → P 已被本公司认领 → 跳过 → null
      → current_target 永远为 null → 永远接不到 P
   ③ 传感器再问 → P 仍被认领 → 也返回 null → 连调试线都不画
   ```
   外部表现："同样空车、没载客，有的车传感器指向乘客、有的什么都不显示"，
   而后者**奖励里没有目标 ⟹ 每帧奖励恒定 ⟹ 梯度为 0**，只会绕圈。
   修法：只读查询走 `peek_best_target_for()` / `peek_passenger()`，写认领只在业务层。
   教训：拿"看起来正常"当验收会漏掉这类 bug（中毒那台车的第一帧是正常的）。

## 四、课程阶段（离线人工切换，Python 侧不认识「阶段」）

| 阶段 | 配置（都在 arena 场景的 `AIParameter` 节点里） |
|---|---|
| Phase 1 验证链路 | `enabled_dense_nav = true`，pickdrop / isMoving 关 |
| Phase 2 端到端接客 | `enabled_dense_nav = false`，`enabled_pickdrop = true`，放宽 `pickup_radius` / `stop_speed_threshold` |

`SteeringSmoothnessReward` 两个阶段都建议保留（只罚方向盘来回猛打，匀速转弯免费）。

## 五、物理帧率与 `speed_up`

`TaxiSync.speed_up` 在 `sync.gd` 里直接写 `Engine.time_scale`，而 Godot 把**物理帧的
delta** 也乘上 time_scale。`project.godot` 里 `common/physics_ticks_per_second = 240`
是配着 `speed_up = 4` 用的：这样每个物理帧恰好推进 `4/240 = 1/60 s` 仿真时间，
`action_repeat = 8` 帧 = 0.133 s 决策一次，`reset_after = 10800` 帧 = 180 s 一回合。
**改 `speed_up` 就要同步改这两个数**，否则所有「帧 ↔ 秒」的换算都会错。
