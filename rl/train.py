"""Taxi 接送任务 PPO 训练。

结构对齐 godot_rl 官方示例 `examples/stable_baselines3_example.py`：
直接使用 `StableBaselinesGodotEnv` + `VecMonitor` + `PPO`，配置全部走 argparse，
不做额外抽象。

用法（两种都行）
----
    # 直接运行（推荐，PyCharm 里直接 Run 也行）
    python rl/train.py --viz

    # 作为模块运行
    python -m rl.train --viz

1) 编辑器内训练（先跑本脚本，再在 Godot 里按 PLAY）：

       python rl/train.py --viz

2) 无头并行训练（先导出 Godot 项目）：

       python rl/train.py --env_path build/AutoFollow.exe --n_parallel 8

3) 只做推理（加载已有模型跑动作，不训练）：

       python rl/train.py --inference --resume_model_path rl/logs/taxi.zip --viz

4) 训练后导出 ONNX（给 Godot 的 ONNX_INFERENCE 模式用）：

       python rl/train.py --onnx_export_path rl/models/taxi.onnx

## 关于课程阶段

课程阶段是**离线人工切换**的：改好 Godot 侧配置再启动一次训练。
本脚本不认识"阶段"这个概念，只需要用 `--experiment_name` 区分不同阶段的日志，
配置清单见 `rl/docs/CURRICULUM.md`。
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys
from collections import deque
from typing import Callable, Deque, Dict, List, Optional, Sequence

import numpy as np

# 允许"直接运行脚本"（python rl/train.py）时也能 import 同目录的 feature_extractors
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback, CallbackList, CheckpointCallback
from stable_baselines3.common.vec_env.vec_monitor import VecMonitor

from feature_extractors import CombinedExtractor, policy_kwargs


# ---------------------------------------------------------------------------
# 补丁：让 Godot 每步发来的 info 真正到达 Python
# ---------------------------------------------------------------------------
# godot_rl 0.8.0 的 `GodotEnv.step_recv()` 结尾是
#     return (..., [{}] * len(response["done"]))
# —— 它**丢弃**了 Godot 每步发过来的 info（Godot 侧 `sync.gd:222` 确实发了
# `{"type":"step", ..., "info": info}`）。而 `AITaxiController.get_info()` 是
# **读后清零**语义：Godot 每步把它读走并清空，Python 这边又扔进垃圾桶。
#
# 后果：`picked_up / delivered / stolen` 永远传不到 Python ⟹ `task/pickups`、
# `task/dropoffs`、`task/success_rate` **结构性恒为 0**。
# 实测代价：车已经真的接到客了（车顶牌照都换了、远程检视器里
# `has_passenger = true`），指标却一直是 0，于是连续几轮都在拿一个假 0 做判断。
#
# 修在这里而不是改 site-packages：pip 重装/升级 godot_rl 都不会把我们的代码冲掉。
# （注意 `ep_len_mean` 不受影响 —— 它走的是 `done`，那条链路是好的。所以
#  "回合从未提前结束" 仍然可信 ⟹ **接客会发生、送达从未发生过**。）
def _patch_godot_env_info() -> None:
    from godot_rl.core.godot_env import GodotEnv

    if getattr(GodotEnv, "_dsh_info_patched", False):
        return

    def step_recv(self):  # type: ignore[no-untyped-def]
        response = self._get_json_dict()
        response["obs"] = self._process_obs(response["obs"])
        done = np.array(response["done"]).tolist()
        info = response.get("info") or [{}] * len(done)
        if len(info) != len(done):
            info = [{}] * len(done)
        # 上游没有区分 term/trunc，这里沿用它的写法
        return response["obs"], response["reward"], done, done, info

    GodotEnv.step_recv = step_recv
    GodotEnv._dsh_info_patched = True
    print("[Patch] godot_rl GodotEnv.step_recv 已打补丁：每步 info 会透传到 Python")

DEFAULT_RAYCAST_DIM = 384
RAYCAST_DIRS = ("front", "back", "left", "right")  # 每方向 96 = far 36 + near 60
RAYCAST_PER_DIR = 96
RAY_FAR_NWH = (6, 3, 2)  # n_rays_width, n_rays_height, 每根(distance, class)
RAY_NEAR_NWH = (10, 3, 2)  # 6*3*2=36, 10*3*2=60


# ---------------------------------------------------------------------------
# 极简指标回调
# ---------------------------------------------------------------------------
class MetricsCallback(BaseCallback):
    """统计接送任务的业务指标，写进 TensorBoard。

    为什么需要：奖励里有势函数塑形（`shaping_scale × 距离减少量`），策略可以靠
    "来回晃悠"刷塑形奖励却一次客都不接。**只看 `rollout/ep_rew_mean` 会被骗**，
    必须看 `task/dropoffs`。

    数据来源：`AITaxiController.get_info()` 返回的
    `picked_up` / `delivered` / `stolen` / `is_success`。
    """

    def __init__(self, window: int = 200, verbose: int = 0) -> None:
        super().__init__(verbose)
        self._success: Deque[float] = deque(maxlen=window)
        self._rewards: Deque[float] = deque(maxlen=window)
        self._lengths: Deque[float] = deque(maxlen=window)
        self._pickups = 0
        self._dropoffs = 0
        self._stolen = 0

    def _on_step(self) -> bool:
        infos: List[Dict] = self.locals.get("infos", []) or []
        dones = self.locals.get("dones", None)

        for i, info in enumerate(infos):
            if info.get("picked_up"):
                self._pickups += 1
            if info.get("delivered"):
                self._dropoffs += 1
            if info.get("stolen"):
                self._stolen += 1

            if dones is not None and i < len(dones) and bool(dones[i]):
                self._success.append(1.0 if info.get("is_success") else 0.0)

            if "episode" in info:
                self._rewards.append(float(info["episode"].get("r", 0.0)))
                self._lengths.append(float(info["episode"].get("l", 0.0)))
        return True

    def _on_rollout_end(self) -> None:
        if self.logger is None:
            return
        if self._success:
            self.logger.record("task/success_rate", float(np.mean(self._success)))
        if self._rewards:
            self.logger.record("task/episode_reward", float(np.mean(self._rewards)))
            self.logger.record("task/episode_length", float(np.mean(self._lengths)))
        self.logger.record("task/pickups", float(self._pickups))
        self.logger.record("task/dropoffs", float(self._dropoffs))
        self.logger.record("task/stolen", float(self._stolen))


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="AutoFollow Taxi RL 训练（PPO）", allow_abbrev=False
    )

    # --- 环境 ---
    parser.add_argument("--env_path", default=None, type=str, help="Godot 可执行文件；不填=编辑器内训练")
    parser.add_argument("--n_parallel", default=1, type=int, help="并行 Godot 实例数（需要 --env_path）")
    parser.add_argument(
        "--seed",
        default=0,
        type=int,
        help="随机种子（仅用于启动 Godot 时的 --env_seed，不会传给 PPO）",
    )
    parser.add_argument("--viz", action="store_true", help="显示 Godot 窗口")
    parser.add_argument(
        "--speedup",
        default=None,
        type=float,
        help="物理加速倍率。不填 = 用 Godot 侧 Sync 节点的 speed_up 导出值"
        "（传了就会覆盖它，因为 godot_rl 里命令行参数优先）",
    )
    parser.add_argument("--action_repeat", default=None, type=int, help="每个动作重复的物理帧数")
    parser.add_argument("--framerate", default=None, type=int, help="固定物理帧率")

    # --- 训练 ---
    parser.add_argument("--timesteps", default=1_000_000, type=int, help="总训练步数")
    parser.add_argument("--learning_rate", default=3e-4, type=float, help="学习率")
    parser.add_argument("--linear_lr_schedule", action="store_true", help="学习率线性衰减到 0")
    parser.add_argument("--n_steps", default=2048, type=int, help="每次更新前收集的步数")
    parser.add_argument("--batch_size", default=256, type=int, help="小批量大小")
    parser.add_argument("--n_epochs", default=10, type=int, help="每批数据重复训练轮数")
    parser.add_argument("--gamma", default=0.99, type=float, help="折扣因子")
    parser.add_argument("--gae_lambda", default=0.95, type=float, help="GAE λ")
    parser.add_argument("--clip_range", default=0.2, type=float, help="PPO 裁剪范围")
    parser.add_argument(
        "--ent_coef",
        default=0.001,
        type=float,
        help="熵系数。默认 0.001（原 0.005）：熵项会把高斯策略的 std 往上推，"
        "和 log_std_init 的'别乱打方向'直接对着干，所以调小了",
    )
    parser.add_argument("--vf_coef", default=0.5, type=float, help="价值损失系数")
    parser.add_argument("--max_grad_norm", default=0.5, type=float, help="梯度裁剪范数")
    parser.add_argument("--device", default="auto", type=str, help="cpu / cuda / auto")
    parser.add_argument(
        "--log_std_init",
        default=-1.0,
        type=float,
        help="连续动作高斯策略的初始 log 标准差（std=e^x）。默认 -1.0（std≈0.37）。"
        "SB3 默认 0.0 → std=1.0，对 [-1,1] 的动作 = 开局方向盘打满、油门均匀随机，"
        "是'训练一开始就猛打方向'的直接原因。想关掉这个先验就填 0.0",
    )
    parser.add_argument(
        "--action_bias",
        default="0,0,-0.5",
        type=str,
        help="策略动作分布的**初始均值**（逗号分隔，顺序必须是 Godot 侧 "
        "AITaxiController.get_action_space() 的声明顺序：throttle,steering,reverse）。"
        "实测 P(reverse>0)：均值 0 → 49%%，-0.5 → 8.7%%，-1.0 → 0.6%%。"
        "默认 -0.5：既要压掉'开局一半步数在倒车'（车原地乱窜），又要留够探索 —— "
        "卡在墙上倒出来需要连续约 8 步倒车，0.6%% 的概率下随机探索永远凑不出来，"
        "策略就学不会倒车（实测车会一直顶着墙）。"
        "留空字符串 = 不改（均值恒为 0）。",
    )

    parser.add_argument(
        "--reset_log_std",
        default="",
        type=str,
        help="**只在续训时生效**：把动作高斯策略的 log 标准差重置成给定量（std=e^x），"
        "用来把已经塌缩的探索重新拉大。单个数=所有维度同值；也可 'a,b,c' 按维度给"
        "（顺序 throttle,steering,reverse）。留空=保持 checkpoint 里的值。"
        "典型用法：策略收敛成'只会直冲'时 --reset_log_std -1.0 --ent_coef 0.01。",
    )

    # --- 网络 ---
    parser.add_argument(
        "--features",
        default="custom",
        choices=["custom", "mlp"],
        help="custom=分塔编码（推荐）；mlp=SB3 默认 MLP（基线）",
    )
    parser.add_argument("--net_arch", default="256,256", type=str, help="主体网络宽度，逗号分隔")
    parser.add_argument("--features_dim", default=128, type=int, help="分塔每组输出维度")
    parser.add_argument(
        "--raycast_dim",
        default=384,
        type=int,
        help="射线段维度。改了场景里的 RayCastSensor3D 配置就要同步改这里",
    )
    parser.add_argument("--position_dim", default=None, type=int, help="位置段维度；不填=自动推算")
    parser.add_argument("--activation", default="relu", choices=["relu", "tanh", "elu"])

    # --- 日志与保存 ---
    parser.add_argument("--experiment_dir", default="rl/logs", type=str, help="TensorBoard 日志目录")
    parser.add_argument("--experiment_name", default="taxi", type=str, help="实验名（TensorBoard 子目录）")
    parser.add_argument("--resume_model_path", default=None, type=str, help="从 .zip 继续训练或推理")
    parser.add_argument("--save_model_path", default=None, type=str, help="训练结束后保存路径（不含扩展名）")
    parser.add_argument(
        "--save_checkpoint_frequency",
        default=200_000,
        type=int,
        help="每 N 个 timestep 存一次检查点（默认 20 万，写到 "
        "<experiment_dir>/<name>_checkpoints/）。默认开启是因为：进程被 Ctrl+C / "
        "Godot 崩溃 / 断电打断时，没有检查点就一无所有。填 0 = 关闭。",
    )
    parser.add_argument("--onnx_export_path", default=None, type=str, help="训练结束后导出 ONNX 的路径")

    # --- 推理 ---
    parser.add_argument("--inference", action="store_true", help="只推理不训练（需要 --resume_model_path）")

    return parser


def linear_schedule(initial_value: float) -> Callable[[float], float]:
    """线性学习率衰减：progress_remaining 从 1 衰减到 0。"""

    def func(progress_remaining: float) -> float:
        return progress_remaining * initial_value

    return func


def parse_action_bias(spec: str, parser: argparse.ArgumentParser) -> Optional[List[float]]:
    """解析 --action_bias。空串 → None（不改均值）。"""
    spec = spec.strip()
    if not spec:
        return None
    try:
        return [float(x) for x in spec.split(",") if x.strip()]
    except ValueError:
        parser.error(f"--action_bias 解析失败：{spec!r}（应为逗号分隔的浮点数）")
        return None


def parse_float_list(
    spec: str, parser: argparse.ArgumentParser, flag: str
) -> Optional[List[float]]:
    """解析 "a" 或 "a,b,c" 形式的浮点列表。空串 → None。"""
    spec = spec.strip()
    if not spec:
        return None
    try:
        return [float(x) for x in spec.split(",") if x.strip()]
    except ValueError:
        parser.error(f"{flag} 解析失败：{spec!r}（应为逗号分隔的浮点数）")
        return None


def apply_log_std_reset(model, values: Sequence[float]) -> None:
    """把策略的 `log_std` 重置成给定量（std = e^x）。只在**续训**时用。

    为什么需要它：`log_std` 是可训练参数，训练久了会一路塌缩 —— 实测 Stage0 收敛后
    `std = [0.276, **0.042**, 0.316]`（throttle/steering/reverse），转向维度基本变成
    确定性。一旦塌缩，策略就只能在原地微调、再也发现不了新行为；而**续训会把这份
    塌缩一起带过来**，所以"从 checkpoint 接着练"永远救不回探索。这个开关就是给它一脚。

    与 `--action_bias` 的分工：偏置管"探索的**中心**"，log_std 管"探索的**幅度**"。
    """
    import torch

    std = getattr(model.policy, "log_std", None)
    if std is None:
        print("[Init] 策略没有 log_std（离散动作？），跳过 --reset_log_std")
        return
    vals = list(values)
    if len(vals) == 1:
        vals = vals * int(std.numel())
    if len(vals) != int(std.numel()):
        print(f"[Init] --reset_log_std 给了 {len(vals)} 个值，动作维度是 {std.numel()}，跳过")
        return
    with torch.no_grad():
        std.data.copy_(torch.tensor(vals, dtype=std.dtype, device=std.device))
    shown = [round(float(torch.tensor(x, dtype=torch.float32).exp()), 3) for x in vals]
    print(f"[Init] log_std 重置为 {vals} → std {shown}（顺序：throttle, steering, reverse）")


def apply_action_bias(model, bias: Sequence[float]) -> None:
    """把策略动作分布的**初始均值**设成 bias。

    连续动作的 `ActorCriticPolicy` 里动作均值 = `action_net(latent_pi)`，而
    `action_net` 最后一层在 `ortho_init`（SB3 默认）下权重 std=0.01、**bias=0**，
    所以初始均值恒为 0。对 `reverse` 这种"用符号表达布尔量"的通道来说，
    均值 0 就意味着开局一半的步数在尝试倒车 —— 车于是原地前后乱窜。

    直接把 bias 写掉，就给每个通道一个先验（且**可训练**，不是硬约束）。

    与 `log_std_init` 的分工：`log_std_init` 控制探索的**幅度**（std），
    本函数控制探索的**中心**（均值）。两者互补，缺一不可：
      - 只调 std：倒车幅度变小，但仍有 50% 概率触发
      - 只调均值：不倒车了，但转向仍会以 std=1.0 打满
    """
    import torch

    net = getattr(model.policy, "action_net", None)
    if net is None or getattr(net, "bias", None) is None:
        print("[Init] 策略没有 action_net.bias（离散动作？），跳过 --action_bias")
        return
    if net.bias.numel() != len(bias):
        print(f"[Init] --action_bias 维度 {len(bias)} != 动作维度 {net.bias.numel()}，跳过")
        return
    with torch.no_grad():
        net.bias.copy_(torch.tensor(list(bias), dtype=net.bias.dtype, device=net.bias.device))
    print(f"[Init] 动作初始均值 = {list(bias)}（顺序：throttle, steering, reverse）")


# ---------------------------------------------------------------------------
def check_env_path(env_path: str, parser: argparse.ArgumentParser) -> None:
    """校验 --env_path 指向真实存在的导出可执行文件。

    godot_rl 内部只会做 `assert os.path.exists(...)`，报错是光秃秃的
    `AssertionError`，完全看不出是路径写错了还是文件没导出。
    这里提前拦下，并把"相对于哪个目录不存在"讲清楚——最常见的坑就是
    在 `rl/` 目录下运行却写了 `Export/xxx.exe`（Export 在项目根目录）。
    """
    p = pathlib.Path(env_path)
    if p.exists():
        return

    abs_path = p.resolve()
    lines = [f"--env_path 指向的文件不存在：{env_path}", f"  解析为绝对路径：{abs_path}"]

    # 向上逐级查找：把"原始相对路径"接到每一级祖先后面再试。
    # 必须带上原始的相对部分（例如 `Export/`），否则会漏掉
    # `<项目根>/Export/xxx.exe` 这种位置。
    if not p.is_absolute():
        for ancestor in abs_path.parents:
            candidate = ancestor / p
            if candidate.exists():
                rel = os.path.relpath(candidate, pathlib.Path.cwd())
                lines.append(f"  你可能想用：{candidate}")
                lines.append(f"  （相对于当前目录：{rel}）")
                break

    lines.append("")
    lines.append("注意：相对路径是相对于**当前工作目录**解析的。")
    lines.append("在 rl/ 目录下运行时，项目根目录的导出文件要写 ../Export/xxx.exe，")
    lines.append("或直接写绝对路径。")
    parser.error("\n".join(lines))


# ---------------------------------------------------------------------------
def main() -> int:
    _patch_godot_env_info()
    parser = build_parser()
    args = parser.parse_args()

    if args.env_path is None and args.n_parallel > 1:
        parser.error("--n_parallel > 1 必须提供 --env_path（编辑器内训练只能单实例）")
    if args.inference and args.resume_model_path is None:
        parser.error("--inference 需要 --resume_model_path")
    if args.env_path is not None:
        check_env_path(args.env_path, parser)
    if args.env_path is None and args.viz:
        print("提示：--viz 在编辑器内训练时无效（编辑器总是渲染）。")

    net_arch = [int(x) for x in args.net_arch.split(",") if x.strip()]
    action_bias = parse_action_bias(args.action_bias, parser)
    reset_log_std = parse_float_list(args.reset_log_std, parser, "--reset_log_std")

    # --- 环境（与官方示例一致：直接用 StableBaselinesGodotEnv）---
    env_kwargs: Dict = {}
    if args.action_repeat is not None:
        env_kwargs["action_repeat"] = args.action_repeat
    if args.framerate is not None:
        env_kwargs["framerate"] = args.framerate
    # speedup 不填就不传：让 godot_rl 走 --speedup 的默认分支，
    # 于是 sync.gd 会退回用检视器里 Sync 节点的 speed_up 导出值。
    # （原先 default=1 且总是传，导致那个导出值在训练时永远不生效）
    if args.speedup is not None:
        env_kwargs["speedup"] = args.speedup

    env = StableBaselinesGodotEnv(
        env_path=args.env_path,
        show_window=args.viz,
        seed=args.seed,
        n_parallel=args.n_parallel,
        **env_kwargs,
    )
    env = VecMonitor(env)

    print(f"[Env] {env.num_envs} 个并行 agent（= AIController 实例数 × 并行实例数）")
    print(f"[Env] 观测空间：{env.observation_space}")
    print(f"[Env] 动作空间：{env.action_space}")

    # --- 网络 ---
    kwargs = policy_kwargs(
        features=args.features,
        net_arch=net_arch,
        features_dim=args.features_dim,
        raycast_dim=args.raycast_dim,
        position_dim=args.position_dim,
        activation=args.activation,
        log_std_init=args.log_std_init,
    )
    if args.features == "custom":
        print("[Net] 观测分组：")
        print(CombinedExtractor(env.observation_space).describe())

    # --- 模型 ---
    if args.resume_model_path is None:
        learning_rate = (
            linear_schedule(args.learning_rate) if args.linear_lr_schedule else args.learning_rate
        )
        model = PPO(
            "MultiInputPolicy",
            env,
            learning_rate=learning_rate,
            n_steps=args.n_steps,
            batch_size=args.batch_size,
            n_epochs=args.n_epochs,
            gamma=args.gamma,
            gae_lambda=args.gae_lambda,
            clip_range=args.clip_range,
            ent_coef=args.ent_coef,
            vf_coef=args.vf_coef,
            max_grad_norm=args.max_grad_norm,
            tensorboard_log=args.experiment_dir,
            policy_kwargs=kwargs,
            device=args.device,
            verbose=1,
            # 注意：不要在这里传 seed。SB3 的 set_random_seed 会调用 VecEnv.seed()，
            # 而 godot_rl 的 StableBaselinesGodotEnv 未实现该方法（直接 NotImplementedError）。
            # Godot 侧的种子只在启动时通过 --env_seed 生效，见上面的 StableBaselinesGodotEnv(seed=...)。
        )
    else:
        path = pathlib.Path(args.resume_model_path)
        print(f"[Train] 加载模型：{path.absolute()}")
        model = PPO.load(
            path,
            env=env,
            tensorboard_log=args.experiment_dir,
            device=args.device,
        )

    # --- 动作初始先验（只对新建的模型；resume 时保留 checkpoint 里学到的均值）---
    if args.resume_model_path is None and action_bias is not None:
        apply_action_bias(model, action_bias)
    # --- 续训时重新拉大探索：checkpoint 里的 log_std 往往已经塌缩 ---
    if args.resume_model_path is not None and reset_log_std is not None:
        apply_log_std_reset(model, reset_log_std)

    # --- 推理模式 ---
    if args.inference:
        _run_inference(env, model, args.timesteps)
        env.close()
        return 0

    # --- 训练 ---
    callbacks = [MetricsCallback(verbose=0)]
    if args.save_checkpoint_frequency:
        ckpt_dir = os.path.join(args.experiment_dir, f"{args.experiment_name}_checkpoints")
        callbacks.append(
            CheckpointCallback(
                # CheckpointCallback.save_freq 的单位是**回调被调用的次数**，也就是
                # 向量步数；每个向量步产生 env.num_envs 条转移。所以要除
                # env.num_envs（官方示例 stable_baselines3_example.py:215 就是这么做的），
                # 不是 n_parallel。原来除 n_parallel（编辑器训练时恒为 1）会把间隔
                # 放大 num_envs 倍 —— 18 个 agent 时表现为"检查点目录建了、
                # 但一个 .zip 都没存下来"。
                save_freq=max(1, args.save_checkpoint_frequency // max(1, env.num_envs)),
                save_path=ckpt_dir,
                name_prefix=args.experiment_name,
            )
        )
        print(f"[Train] 检查点目录：{os.path.abspath(ckpt_dir)}")

    try:
        model.learn(
            total_timesteps=args.timesteps,
            callback=CallbackList(callbacks),
            tb_log_name=args.experiment_name,
            reset_num_timesteps=args.resume_model_path is None,
        )
    except (KeyboardInterrupt, ConnectionError, ConnectionResetError) as exc:
        print(f"\n[Train] 训练中断（{type(exc).__name__}），保存当前模型…")

    # --- 保存与导出 ---
    # ⚠️ 默认也要存。权重只活在进程内存里：一个跑了几小时的 run 如果因为"没写
    # --save_model_path"而在结束/中断时什么都不留下，是不可逆的损失
    # （实测踩过：看到一个能自己绕到乘客旁边的策略，磁盘上却一个 .zip 都没有）。
    # 没显式指定就落到 <experiment_dir>/<experiment_name>_final.zip。
    save_path = (
        pathlib.Path(args.save_model_path)
        if args.save_model_path
        else pathlib.Path(args.experiment_dir) / f"{args.experiment_name}_final"
    ).with_suffix(".zip")
    save_path.parent.mkdir(parents=True, exist_ok=True)
    model.save(save_path)
    print(f"[Train] 模型已保存：{save_path.absolute()}（--resume_model_path 传它即可续训）")

    if args.onnx_export_path:
        export_onnx(model, args.onnx_export_path)

    env.close()
    return 0


def _run_inference(env, model, steps: int) -> None:
    """加载模型跑动作，不训练。用于快速看策略行为。"""
    print(f"[Inference] 跑 {steps} 步（确定性动作）")
    obs = env.reset()
    for _ in range(steps):
        action, _ = model.predict(obs, deterministic=True)
        obs, _reward, _done, _info = env.step(action)


def export_onnx(model, onnx_path: str) -> None:
    """导出 ONNX 供 Godot 的 ONNX_INFERENCE 模式使用。

    不使用 godot_rl 自带的导出器，因为它在当前环境里两条路都走不通：

    1. `godot_rl/wrappers/onnx/stable_baselines_export.py:2` 的
       `from gymnasium.vector.utils import spaces` 在 gymnasium 1.3 上是 ImportError
       （那个名字已经不存在了，只有 `space_utils`）。
    2. torch 2.14 的 `torch.onnx.export` 默认走新的 dynamo 导出器，需要 onnxscript
       （未安装）；而旧导出器不接受 dict 形式的观测输入。

    所以这里用 `dynamo=False` 的 TorchScript 导出器，并把观测作为**扁平张量列表**
    （每个 obs key 一个张量）传入 —— 与 godot_rl 官方导出器的做法一致。

    导出契约必须与 Godot 侧一致（`addons/godot_rl_agents/onnx/csharp/ONNXInference.cs:39-63`）：

        输入  "obs"        float32 [batch, 419]
        输入  "state_ins"  float32 [batch]
        输出  "output"     float32 [batch, 3]    动作均值
        输出  "state_outs" float32 [batch]        原样透传 state_ins

    注意 `state_ins` 必须是**图输入并透传**：Godot 会显式喂它，并在
    `OutputMetadata["output"].Dimensions[1]` 里读动作维度。
    """
    import torch

    path = pathlib.Path(onnx_path).with_suffix(".onnx")
    path.parent.mkdir(parents=True, exist_ok=True)

    policy = model.policy.to("cpu").eval()
    obs_space = model.observation_space
    if hasattr(obs_space, "spaces"):
        obs_keys = sorted(obs_space.spaces)
        shapes = {k: tuple(obs_space[k].shape) for k in obs_keys}
    else:
        obs_keys, shapes = ["obs"], {"obs": tuple(obs_space.shape)}

    class _OnnxablePolicy(torch.nn.Module):
        def __init__(self, policy, obs_keys):
            super().__init__()
            self.policy = policy
            self.obs_keys = tuple(obs_keys)

        def forward(self, obs, state_ins):
            # obs 是扁平化后的输入列表：每个观测 key 对应一个张量
            obs_dict = {k: v for k, v in zip(self.obs_keys, obs)}
            actions = self.policy.get_distribution(obs_dict).get_actions(deterministic=True)
            return actions, state_ins

    wrapped = _OnnxablePolicy(policy, obs_keys)
    dummy_obs = [torch.zeros(1, *shapes[k], dtype=torch.float32) for k in obs_keys]
    dummy_state = torch.zeros(1, dtype=torch.float32)

    torch.onnx.export(
        wrapped,
        args=(dummy_obs, dummy_state),
        f=str(path),
        opset_version=17,
        input_names=list(obs_keys) + ["state_ins"],
        output_names=["output", "state_outs"],
        dynamic_axes={
            **{k: {0: "batch_size"} for k in obs_keys},
            "state_ins": {0: "batch_size"},
            "output": {0: "batch_size"},
            "state_outs": {0: "batch_size"},
        },
        dynamo=False,  # 必须：绕开需要 onnxscript 的 dynamo 导出器
    )
    print(f"[ONNX] 已导出：{path.absolute()}")
    _verify_onnx(model, str(path), obs_keys, shapes)


def _verify_onnx(model, path: str, obs_keys, shapes, n_tests: int = 5) -> None:
    """用 onnxruntime 跑几组随机观测，确认导出图和 SB3 的输出一致。

    不做校验的话，"导出成功"和"导出正确"是两件事 —— 轴序/输入名写错也能导出成功。
    """
    import torch

    try:
        import onnxruntime as ort
    except ImportError as exc:
        print(f"[ONNX] 跳过校验（{exc}）")
        return

    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    policy = model.policy.to("cpu").eval()
    worst = 0.0
    for _ in range(n_tests):
        obs_np = {
            k: np.random.uniform(-1.0, 1.0, (1, *shapes[k])).astype(np.float32) for k in obs_keys
        }
        state_np = np.zeros(1, dtype=np.float32)
        with torch.no_grad():
            ref = (
                policy.get_distribution({k: torch.as_tensor(v) for k, v in obs_np.items()})
                .get_actions(deterministic=True)
                .numpy()
            )
        got = sess.run(None, {**obs_np, "state_ins": state_np})[0]
        worst = max(worst, float(np.abs(ref - got).max()))
    if worst > 1e-5:
        raise RuntimeError(f"[ONNX] 校验失败：与 SB3 输出最大偏差 {worst:.3e}")
    print(f"[ONNX] 校验通过：{n_tests} 组随机观测与 SB3 一致（最大偏差 {worst:.2e}）")


if __name__ == "__main__":
    raise SystemExit(main())
