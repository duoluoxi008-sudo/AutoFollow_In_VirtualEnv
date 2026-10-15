"""离线自检：只验证策略网络的形状契约（不连接 Godot）。

运行（两种都行）：

    python rl/selftest.py           # 直接运行
    python -m rl.selftest           # 作为模块运行

作用：改完网络结构后 3 秒内确认没有破坏 shape 契约，不用等 Godot 握手。
"""

from __future__ import annotations

import os
import sys

import numpy as np
#: 默认射线段长度（见模块 docstring 的算法）
DEFAULT_RAYCAST_DIM = 384
RAYCAST_DIRS = ("front", "back", "left", "right")  # 每方向 96 = far 36 + near 60
RAYCAST_PER_DIR = 96
RAY_FAR_NWH = (6, 3, 2)  # n_rays_width, n_rays_height, 每根(distance, class)
RAY_NEAR_NWH = (10, 3, 2)  # 6*3*2=36, 10*3*2=60


# 允许"直接运行脚本"时也能 import 同目录的 feature_extractors
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def check(label: str, ok: bool, detail: str = "") -> bool:
    print(f"[{'PASS' if ok else 'FAIL'}] {label}" + (f"  — {detail}" if detail else ""))
    return ok


def main() -> int:
    import gymnasium as gym
    import torch
    from gymnasium import spaces
    from stable_baselines3 import PPO

    from feature_extractors import SELF_STATE_DIM, CombinedExtractor, policy_kwargs

    total = 419  # 8 (自车) + 384 (射线) + 27 (位置)
    obs_space = spaces.Dict({"obs": spaces.Box(-1.0, 1.0, shape=(total,), dtype=np.float32)})

    results = []

    # --- 1. 分塔前向 ---
    extractor = CombinedExtractor(obs_space, features_dim=128, raycast_dim=384)
    print(extractor.describe())
    obs = {"obs": torch.as_tensor(np.random.randn(4, total).astype(np.float32))}
    out = extractor(obs)

    results.append(check("分塔前向", tuple(out.shape) == (4, 384), str(tuple(out.shape))))
    results.append(
        check(
            "分组维度之和 == 观测维度",
            extractor.self_state_dim + extractor.raycast_dim + extractor.position_dim == total,
            f"{SELF_STATE_DIM}+{extractor.raycast_dim}+{extractor.position_dim}={total}",
        )
    )
    # --- 1b. 索引表自证：每个子块到底吃了原始向量的哪一段 ---
    ids = torch.arange(total, dtype=torch.float32).reshape(1, total)
    far, near = extractor._split_rays(ids)
    print("\n射线子块 -> 原始索引区间：")
    for d, dname in enumerate(RAYCAST_DIRS):
        f = far[0, d, :, :, 0]
        n = near[0, d, :, :, 0]
        print(f"  {dname:>6}  far {int(f.min()):3d}..{int(f.max()):3d}"
              f"   near {int(n.min()):3d}..{int(n.max()):3d}")
    ids = torch.arange(36, dtype=torch.float32).reshape(1, 36)
    img = ids.reshape(1, 6, 3, 2).permute(0, 3, 1, 2)
    print(img[0, 0, :, 0])  # 距离通道、仰角行 j=0 的所有方位
    print(img[0, 0, 0, :])  # 距离通道、方位列 i=0 的所有仰角
    # --- 2. 维度不符时兜底（不崩）---
    shorter = {"obs": torch.as_tensor(np.random.randn(2, total - 10).astype(np.float32))}
    results.append(check("维度不足时兜底", extractor(shorter).shape[0] == 2))

    # --- 3. 展平观测空间 ---
    flat = spaces.Box(-1.0, 1.0, shape=(total,), dtype=np.float32)
    flat_ex = CombinedExtractor(flat, features_dim=64, raycast_dim=384)
    results.append(
        check("展平观测空间前向", flat_ex(torch.as_tensor(np.random.randn(3, total).astype(np.float32))).shape[0] == 3)
    )

    # --- 4. policy_kwargs ---
    results.append(
        check(
            "policy_kwargs(custom) 含提取器",
            policy_kwargs("custom", [256, 256]).get("features_extractor_class") is CombinedExtractor,
        )
    )
    results.append(check("policy_kwargs(mlp) 不含提取器", "features_extractor_class" not in policy_kwargs("mlp", [128])))

    # --- 5. 真建一次 SB3 网络 ---
    # 注意：SB3 的动作空间只支持 Box/Discrete。godot_rl 的 ActionSpaceProcessor
    # 会把 Godot 上报的 3 键 Dict 动作空间（throttle/steering/brake）压成 Box(3)。
    class _DummyEnv(gym.Env):
        observation_space = obs_space
        action_space = spaces.Box(-1.0, 1.0, shape=(3,), dtype=np.float32)

        def reset(self, *, seed=None, options=None):
            return {"obs": np.zeros(total, dtype=np.float32)}, {}

        def step(self, action):
            return {"obs": np.zeros(total, dtype=np.float32)}, 0.0, False, False, {}

    policy = PPO(
        "MultiInputPolicy",
        _DummyEnv(),
        policy_kwargs=policy_kwargs("custom", [256, 256], raycast_dim=384),
        n_steps=32,
        batch_size=32,
        device="cpu",
    ).policy
    actions = policy.get_distribution(obs).get_actions(deterministic=True)
    results.append(
        check("SB3 建网 + 前向", actions.shape == (4, 3), f"动作 shape={tuple(actions.shape)}")
    )
    print(f"      动作示例：{actions[0].detach().numpy()}")

    print()
    if all(results):
        print("自检通过 [OK]")
        return 0
    print(f"自检未通过 [FAIL]（{results.count(False)}/{len(results)} 项失败）")
    return 1


if __name__ == "__main__":
    sys.exit(main())
