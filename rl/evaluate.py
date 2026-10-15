"""模型评估：加载已训练模型跑若干回合，输出接送任务的业务指标。

结构同样对齐官方示例：直接 `StableBaselinesGodotEnv` + argparse。

用法（两种都行）
----
    # 直接运行
    python rl/evaluate.py --model rl/logs/taxi.zip --viz

    # 作为模块运行
    python -m rl.evaluate --model rl/logs/taxi.zip --viz

    # 无头评估，跑 20 个回合
    python rl/evaluate.py --model rl/logs/taxi.zip --env_path build/AutoFollow.exe --episodes 20

注意：评估时的 Godot 场景配置必须和训练时一致，否则指标没有可比性。
本脚本不修改环境。
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import List

import numpy as np

# 允许"直接运行脚本"时也能 import 同目录模块（当前无依赖，保留以保持一致）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
from stable_baselines3 import PPO

# 复用 train.py 里的补丁（同一份实现，避免两处漂移）：
# godot_rl 0.8.0 的 `GodotEnv.step_recv()` 把每步 info 丢成 `[{}] * n`，而 Godot 侧
# `AITaxiController.get_info()` 又是**读后清零** ⟹ 不加这个补丁，本脚本读到的
# `delivered / stolen / is_success` 全是空，**送达成功率会永远显示 0%**。
from train import _patch_godot_env_info


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Taxi RL 模型评估", allow_abbrev=False)
    parser.add_argument("--model", required=True, type=str, help="已训练的 .zip 模型路径")
    parser.add_argument("--env_path", default=None, type=str, help="Godot 可执行文件；不填=编辑器内")
    parser.add_argument("--n_parallel", default=1, type=int, help="并行实例数（需要 --env_path）")
    parser.add_argument("--viz", action="store_true", help="显示 Godot 窗口")
    parser.add_argument(
        "--speedup",
        default=None,
        type=int,
        help="物理加速倍率。**默认不传** = 沿用 Godot 侧 Sync 节点的 speed_up —— "
        "评估必须和训练用同一个物理步长，否则动力学都不一致，指标没有可比性"
        "（train.py 里同样不再默认传 1，原因见那边的注释）",
    )
    parser.add_argument("--seed", default=0, type=int, help="随机种子")
    parser.add_argument("--episodes", default=10, type=int, help="评估回合数（所有 agent 合计）")
    parser.add_argument("--device", default="auto", type=str, help="cpu / cuda / auto")
    parser.add_argument("--stochastic", action="store_true", help="用随机策略而非确定性动作")
    return parser


def main() -> int:
    _patch_godot_env_info()
    args = build_parser().parse_args()

    env_kwargs = {}
    if args.speedup is not None:
        env_kwargs["speedup"] = args.speedup

    env = StableBaselinesGodotEnv(
        env_path=args.env_path,
        show_window=args.viz,
        seed=args.seed,
        n_parallel=args.n_parallel,
        **env_kwargs,
    )
    print(f"[Eval] {env.num_envs} 个并行 agent")
    print(f"[Eval] 观测空间：{env.observation_space}")

    model = PPO.load(args.model, env=None, device=args.device)
    print(f"[Eval] 模型已加载：{args.model}")

    try:
        _run(env, model, args.episodes, stochastic=args.stochastic)
    finally:
        env.close()
    return 0


def _run(env, model, target_episodes: int, stochastic: bool) -> None:
    obs = env.reset()
    ep_returns = np.zeros(env.num_envs, dtype=np.float32)
    ep_lengths = np.zeros(env.num_envs, dtype=np.int32)
    ep_dropoffs = np.zeros(env.num_envs, dtype=np.int32)
    ep_stolen = np.zeros(env.num_envs, dtype=np.int32)

    returns: List[float] = []
    lengths: List[int] = []
    dropoffs: List[int] = []
    stolen: List[int] = []
    success: List[bool] = []

    total_steps = 0
    max_steps = 2_000_000  # 安全上限，避免环境卡住时死循环

    while len(returns) < target_episodes and total_steps < max_steps:
        actions, _ = model.predict(obs, deterministic=not stochastic)
        obs, rewards, dones, infos = env.step(actions)
        total_steps += 1

        ep_returns += rewards
        ep_lengths += 1
        for i, info in enumerate(infos):
            if info.get("delivered"):
                ep_dropoffs[i] += 1
            if info.get("stolen"):
                ep_stolen[i] += 1

        for i, done in enumerate(dones):
            if not done:
                continue
            returns.append(float(ep_returns[i]))
            lengths.append(int(ep_lengths[i]))
            dropoffs.append(int(ep_dropoffs[i]))
            stolen.append(int(ep_stolen[i]))
            success.append(bool(infos[i].get("is_success", False)))
            ep_returns[i] = 0.0
            ep_lengths[i] = 0
            ep_dropoffs[i] = 0
            ep_stolen[i] = 0

    n = len(returns)
    print("\n" + "=" * 60)
    print(f"评估结果（{n} 个回合，共 {total_steps} 步）")
    print("=" * 60)
    if n == 0:
        print("未完成任何回合：检查 reset_after 是否过大，或环境是否卡住。")
        return
    print(f"平均回合奖励      : {np.mean(returns):8.3f}  ± {np.std(returns):.3f}")
    print(f"平均回合长度      : {np.mean(lengths):8.1f}  步")
    print(f"平均送达数/回合   : {np.mean(dropoffs):8.2f}")
    print(f"平均被抢客数/回合 : {np.mean(stolen):8.2f}")
    print(f"送达成功率        : {np.mean(success) * 100:8.1f}%")
    print("=" * 60)


if __name__ == "__main__":
    raise SystemExit(main())
