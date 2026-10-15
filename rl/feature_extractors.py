"""策略网络：观测分塔编码。

## 为什么不用默认的 MLP

`AITaxiController.get_obs()` 返回的是一段**扁平向量**，但内部是三块语义完全不同的东西：

    [0:8]      自车状态        8 维   归一化后大致 [-1,1]，密集
    [8:392]    射线传感器    384 维   绝大多数是 0.0（未命中），稀疏
    [392:419]  位置传感器     27 维   [-1,1]，结构化

（总维度 419。早期这里写过 615/223，是错的 —— 以 `env.observation_space` 实际打印的
`Box(-1, 1, (419,))` 为准，下面那张区间表也是 419 口径。）

直接喂给 SB3 默认的 `[256, 256]` MLP 有两个问题：

1. **尺度失衡**：射线占 384/615 ≈ 62% 的输入维度，首层的梯度被它主导，
   策略容易只学"避障"而忽略"该去哪接客"。
2. **结构被抹平**：射线本质是 2D 空间采样（前/后/左/右 各 6×3 或 10×3），
   全连接层无法利用这个空间邻接结构。

分塔（split-tower）的做法：每组一个独立线性层 + 隐藏层，压到统一维度后拼接，
再送进 PPO 的 `mlp_extractor`。不换算法，不改 Godot 侧，只换特征提取器。

## 分组维度怎么算

`AITaxiController.get_obs()` 的拼接顺序固定，所以只要知道射线段长度 R 就能切分。
R 由场景里各 `RayCastSensor3D` 的 `n_rays_width × n_rays_height × (1 + class_sensor)`
求和得到。当前 `mmt_ai_sedan.tscn` 的配置：

    前/后/左/右 各两个传感器（远 6×3 + 近 10×3），class_sensor=true
    (6*3 + 10*3) * 2 * 4 = 384

**如果你改了传感器配置，把 `--raycast_dim` 改成新的实际值**，
否则分组会错位（`forward` 里有裁/补兜底，不会崩，但语义会乱）。
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

import torch
import torch.nn as nn
from gymnasium import spaces
from stable_baselines3.common.torch_layers import BaseFeaturesExtractor

#: 自车状态维度，对应 get_obs() 里直接 append 的 8 个标量：
#: 回合进度 / 前向车速 / 横向车速 / 横摆角速度 / 转向角 / 转速 / 挡位 / 是否着地
SELF_STATE_DIM = 8

#: 默认射线段长度（见模块 docstring 的算法）
DEFAULT_RAYCAST_DIM = 384
RAYCAST_DIRS = ("front", "back", "left", "right")  # 每方向 96 = far 36 + near 60
RAYCAST_PER_DIR = 96
RAY_FAR_NWH = (6, 3, 2)  # n_rays_width, n_rays_height, 每根(distance, class)
RAY_NEAR_NWH = (10, 3, 2)  # 6*3*2=36, 10*3*2=60
#: 单个传感器的观测宽度 = n_rays_width × n_rays_height × 每根值数
RAY_FAR_DIM = RAY_FAR_NWH[0] * RAY_FAR_NWH[1] * RAY_FAR_NWH[2]  # 36
RAY_NEAR_DIM = RAY_NEAR_NWH[0] * RAY_NEAR_NWH[1] * RAY_NEAR_NWH[2]  # 60
#: 沿方位角做 1D 卷积时的通道数 = 仰角数 × 每根值数（far/near 必须一致才能共用卷积）
RAY_CONV_CHANNELS = RAY_FAR_NWH[1] * RAY_FAR_NWH[2]  # 3 × 2 = 6


#从Godot返回的默认扁平观察值
#	传感器	在 419 里的区间	长度
#—	自车状态	[0, 8)	8
#0	FarSightFront	[8, 44)	36
#1	NearSightFront	[44, 104)	60
#2	FarSightBack	[104, 140)	36
#3	NearSightBack	[140, 200)	60
#4	FarSightLeft	[200, 236)	36
#5	NearSightLeft	[236, 296)	60
#6	FarSightRight	[296, 332)	36
#7	NearSightRight	[332, 392)	60
#—	位置段	[392, 419)	27
class _RaycastGroup(nn.Module):
    """射线段 (B, raycast_dim) -> (B, out_dim)：沿方位角的共享 1D 卷积。

    ## 为什么是卷积

    动机是**方位角平移等变性**：柱子、墙、车辆、乘客在任何方位角上长得都一样，
    所以应该用同一套检测器去识别，而不是为"第 3 列"和"第 5 列"各学一遍权重。
    这在 LiDAR / 雷达 RL 里是标准做法（把传感器环当成 1D 信号）。

    ## 为什么 1D 而不是 2D

    每根射线在扁平向量里的顺序是 ``i*(H*NV) + j*NV + k``（i=方位角，j=仰角，
    k∈{距离, 类别}）。物理上有意义的空间轴是**方位角**；仰角只有 3 个离散采样
    （地面车辆的上/中/下大致就是天空/地平线/地面），把它当通道比当空间轴更合理。
    所以卷积通道 = H × NV = 3 × 2 = 6，卷积方向 = 方位角。
    （轴序已用 ``torch.arange`` 自证：通道 0 沿方位角读出 [0,6,12,18,24,30]。）

    ## 8 个块共用一套权重

    4 方向 × (far, near) 共 8 个块，通道结构相同（都是 6），而 Conv1d 对长度不敏感，
    所以 far（方位 6 列）和 near（方位 10 列）能走同一条通路。共用会让 8 个块对
    相同输入产生相同输出 —— 方向/尺度的身份靠 ``emb`` 表加回来。

    各块在扁平向量里的顺序 = `mmt_ai_sedan.tscn` 中 `Rl/Sensor/RayCast` 的子节点
    声明顺序（FarSightFront, NearSightFront, FarSightBack, NearSightBack,
    FarSightLeft, NearSightLeft, FarSightRight, NearSightRight）；
    已用撞墙探针实测确认 block 0=front, 1=back, 2=left, 3=right。

    ## 张量流（B=batch，D=4 方向，NV=2）::

        x (B, 384)
          reshape -> (B, D, 96)                      # 每方向 96 = far 36 + near 60
          far  (B, D, 36) -> (B*D, 6, W=6)
          near (B, D, 60) -> (B*D, 6, W=10)
          [共享]  Conv1d(6->hidden, k=3) ×2
                  MaxPool1d(pool_kernel)             # 对长度不敏感 -> 可导出
          [每尺度] Flatten -> Linear(hidden*(W/pool_kernel) -> per_block)
          + emb[scale, dir]
          -> cat -> (B, D, 2*per_block) -> (B, out_dim) -> LayerNorm(out_dim)

    其中 ``per_block = out_dim // (2*D)``，8 个块拼起来正好等于 ``out_dim``，
    所以这一组不改变总输出宽度（不膨胀）。
    """

    def __init__(
        self,
        n_dirs: int,
        out_dim: int,
        hidden: int = 64,
        pool_kernel: int = 2,
    ) -> None:
        super().__init__()
        n_scales = 2  # far / near
        n_blocks = n_scales * n_dirs
        assert out_dim % n_blocks == 0, (
            f"out_dim={out_dim} 必须能被射线块数 {n_blocks} 整除"
        )
        assert (RAY_FAR_NWH[1], RAY_FAR_NWH[2]) == (RAY_NEAR_NWH[1], RAY_NEAR_NWH[2]), (
            "far/near 的 (仰角数, 每根值数) 不一致，无法共用同一个卷积"
        )

        self.n_dirs = n_dirs
        self.per_block = out_dim // n_blocks
        self.pool_kernel = pool_kernel
        #: (宽度 W, 通道数 H*NV)，顺序 = (far, near)
        self.shapes = (
            (RAY_FAR_NWH[0], RAY_FAR_NWH[1] * RAY_FAR_NWH[2]),
            (RAY_NEAR_NWH[0], RAY_NEAR_NWH[1] * RAY_NEAR_NWH[2]),
        )

        # 卷积主干：far(W=6) 和 near(W=10) 共用，这是"方位角平移等变性"的载体。
        # 池化必须对长度不敏感，所以用固定 kernel/stride 的 MaxPool1d，
        # **不能**用 AdaptiveAvgPool1d —— 后者要求静态输入长度，而主干被两个不同
        # 长度共用后，torch.onnx 追踪到的长度会变成符号 *，导出直接报
        # "Unsupported: ONNX export of operator adaptive_avg_pool1d,
        #  input size not accessible"。
        # 用 Max 而不是 Avg：射线绝大多数是"未命中 = 0.0"，均值会把命中稀释掉。
        self.body = nn.Sequential(
            nn.Conv1d(RAY_CONV_CHANNELS, hidden, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.MaxPool1d(pool_kernel, pool_kernel),
        )
        # head 按尺度各一份：池化后长度是 W // pool_kernel，两个尺度不同（3 vs 5），
        # 没法共用。参数代价很小（~4k），换来的是可导出。
        self.heads = nn.ModuleList(
            nn.Sequential(
                nn.Flatten(),
                nn.Linear(hidden * (w // pool_kernel), self.per_block),
            )
            for (w, _channels) in self.shapes
        )
        self.norm = nn.LayerNorm(out_dim)
        #: (n_scales, n_dirs, per_block) —— 把共享卷积丢掉的方向/尺度身份补回来
        self.emb = nn.Parameter(torch.zeros(n_scales, n_dirs, self.per_block))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        B = x.shape[0]
        D = self.n_dirs
        ray = x.reshape(B, D, RAYCAST_PER_DIR)

        feats = []
        offset = 0
        for s, (dim, (w, channels)) in enumerate(
            ((RAY_FAR_DIM, self.shapes[0]), (RAY_NEAR_DIM, self.shapes[1]))
        ):
            blk = ray[:, :, offset : offset + dim]              # (B, D, dim)
            offset += dim
            # 扁平顺序是 i*(H*NV)+m，所以 (B*D, W, channels) 再转置就得到
            # (B*D, channels, W)（通道 = 仰角×值，长度 = 方位角）
            blk = blk.reshape(B * D, w, channels).transpose(1, 2)
            f = self.heads[s](self.body(blk))                    # (B*D, per_block)
            f = f + self.emb[s].repeat(B, 1)                     # 补回身份
            feats.append(f.reshape(B, D, self.per_block))         # (B, D, per_block)

        out = torch.cat(feats, dim=-1).reshape(B, -1)             # (B, out_dim)
        return self.norm(out)


class CombinedExtractor(BaseFeaturesExtractor):
    """按语义切分扁平观测，分别编码后拼接。

    Args:
        observation_space: `Dict{"obs": Box(n,)}` 或 `Box(n,)`。
        features_dim: 每个分组编码到的维度（输出总维度 = features_dim × 分组数）。
        raycast_dim: 射线分组维度。
        position_dim: 位置分组维度；None = 用总维度减去另外两组。
        tower_hidden: self / position 两个塔的隐藏层宽度。
        ray_conv_hidden: 射线组共享卷积的隐藏通道数。
        ray_pool_kernel: 射线组沿方位角的池化核/步长（2 = 每 2 列合成 1 段）。
    """

    def __init__(
            self,
            observation_space: spaces.Space,
            features_dim: int = 128,
            raycast_dim: Optional[int] = DEFAULT_RAYCAST_DIM,
            position_dim: Optional[int] = None,
            tower_hidden: int = 128,
            ray_conv_hidden: int = 64,
            ray_pool_kernel: int = 2,
            self_state_dim: int = SELF_STATE_DIM,
    ) -> None:
        super().__init__(observation_space, features_dim)

        total_dim = _flat_dim(observation_space)
        self._total_dim = total_dim
        self.self_state_dim = self_state_dim

        raycast_dim = DEFAULT_RAYCAST_DIM if raycast_dim is None else raycast_dim
        if position_dim is None:
            position_dim = max(0, total_dim - self_state_dim - raycast_dim)

        # 三段之和不能超过总维度
        overflow = self_state_dim + raycast_dim + position_dim - total_dim
        if overflow > 0:
            raycast_dim = max(0, raycast_dim - overflow)
        n_dirs = len(RAYCAST_DIRS)
        assert RAY_FAR_DIM + RAY_NEAR_DIM == RAYCAST_PER_DIR, (
            f"每方向 {RAY_FAR_DIM}+{RAY_NEAR_DIM} != RAYCAST_PER_DIR {RAYCAST_PER_DIR}"
        )
        assert n_dirs * RAYCAST_PER_DIR == raycast_dim, (
            f"射线子维度 {n_dirs}×{RAYCAST_PER_DIR} != raycast_dim {raycast_dim}"
        )
        assert self_state_dim + raycast_dim + position_dim == total_dim, (
            f"{self_state_dim}+{raycast_dim}+{position_dim} != total_dim {total_dim}"
        )

        self.raycast_dim = raycast_dim
        self.position_dim = position_dim
        # (name, in_dim, out_dim)。射线那一项在 _RaycastGroup 内部自己拆成
        # 4 方向 × (far, near) = 8 个块，但对外仍是一个 out_dim 宽的段，
        # 所以这里回到三段式，out 之和 = 3 × features_dim = 384（不膨胀）。
        self._layout: List[Tuple[str, int, int]] = [
            ("self", self_state_dim, features_dim),
            ("raycast", raycast_dim, features_dim),
            ("position", position_dim, features_dim),
        ]

        # --- 每个分组一个塔 ---
        self.towers = nn.ModuleDict()
        for name, in_dim, out_dim in self._layout:
            if in_dim <= 0 or out_dim <= 0:
                continue
            if name == "raycast":
                self.towers[name] = _RaycastGroup(
                    n_dirs=n_dirs,
                    out_dim=out_dim,
                    hidden=ray_conv_hidden,
                    pool_kernel=ray_pool_kernel,
                )
            else:
                self.towers[name] = nn.Sequential(
                    nn.Linear(in_dim, tower_hidden),
                    nn.LayerNorm(tower_hidden),  # 稳住稀疏输入（射线 0.0 扎堆）的方差
                    nn.ReLU(),
                    nn.Linear(tower_hidden, out_dim),
                    nn.ReLU(),
                )

        self._out_dim = sum(out_dim for _, _, out_dim in self._layout)  # 384
        self._features_dim = self._out_dim

    # ------------------------------------------------------------------
    def forward(self, observations) -> torch.Tensor:
        x = _to_flat_tensor(observations)
        # 兜底：环境给的长度和构造时不一致时裁/补，避免直接崩
        if x.shape[-1] != self._total_dim:
            x = _resize_last_dim(x, self._total_dim)
        parts: List[torch.Tensor] = []
        # _layout 的 in_dim 顺序 == 扁平向量的实际段顺序（8 段偏移见模块顶部注释表，
        # 已用 torch.arange 自证），所以顺序切片即可，不需要 reshape。
        offset = 0
        for name, in_dim, _out_dim in self._layout:
            if in_dim <= 0:
                continue
            parts.append(self.towers[name](x[..., offset : offset + in_dim]))
            offset += in_dim
        if not parts:
            return x
        return torch.cat(parts, dim=-1)

    # ------------------------------------------------------------------
    def describe(self) -> str:
        """打印分组情况，训练启动时显示，便于确认维度没配错。"""
        lines = [f"CombinedExtractor(total_dim={self._total_dim}, out_dim={self._out_dim})"]
        for name, in_dim, out_dim in self._layout:
            lines.append(f"  - {name:<16} in={in_dim:<5} -> {out_dim}")
        return "\n".join(lines)

    def _split_rays(self, x: torch.Tensor):
        """(B, raycast_dim) -> far/near 各 (B, n_dirs, W, H, 2)。

        方向轴顺序见 RAYCAST_DIRS。注意 forward 目前只用顺序切片，
        这个 helper 是留给"按角度做 2D 卷积"那一步的（reshape 会校验元素数）。
        """
        B = x.shape[0]
        n_dirs = len(RAYCAST_DIRS)
        ray = x[:, self.self_state_dim : self.self_state_dim + self.raycast_dim]
        ray = ray.reshape(B, n_dirs, RAYCAST_PER_DIR)
        far = ray[:, :, :RAY_FAR_DIM].reshape(B, n_dirs, *RAY_FAR_NWH)
        near = ray[:, :, RAY_FAR_DIM:].reshape(B, n_dirs, *RAY_NEAR_NWH)
        return far, near


def policy_kwargs(
        features: str = "custom",
        net_arch: Sequence[int] = (256, 256),
        obs_space: Optional[spaces.Space] = None,
        features_dim: int = 128,
        raycast_dim: Optional[int] = DEFAULT_RAYCAST_DIM,
        position_dim: Optional[int] = None,
        activation: str = "relu",
        log_std_init: Optional[float] = None,
) -> Dict:
    """构造 SB3 的 `policy_kwargs`。

    features="custom" → `CombinedExtractor` 分塔编码（推荐）
    features="mlp"    → SB3 默认 MLP（基线，用来对比分塔是否真的有用）

    log_std_init: 连续动作高斯策略的**初始** log 标准差（std = e^x）。
        SB3 默认 0.0 → std = 1.0，而动作空间是 [-1,1]，等于"开局方向盘/油门
        都是均匀随机"（转向直接打满、倒车通道 50% 触发）。实测表现就是车在原地
        猛打方向 + 随机前进/倒车，进度奖励的梯度被噪声淹没。
        -1.0 → std ≈ 0.37（转向 ±13°，倒车仍有 50% 概率但幅度小）。
        注意它只改**幅度**，不改各动作维度的正负概率 —— 后者要靠
        `train.py` 的 `--action_bias`（动作均值偏置）。
    """
    kwargs: Dict = {
        "net_arch": list(net_arch),
        "activation_fn": {"relu": nn.ReLU, "tanh": nn.Tanh, "elu": nn.ELU}[activation],
    }
    if log_std_init is not None:
        kwargs["log_std_init"] = float(log_std_init)
    if features == "custom":
        kwargs["features_extractor_class"] = CombinedExtractor
        kwargs["features_extractor_kwargs"] = {
            "features_dim": features_dim,
            "raycast_dim": raycast_dim,
            "position_dim": position_dim,
        }
    elif features != "mlp":
        raise ValueError(f"未知的 features：{features}（可选 mlp / custom）")
    return kwargs


# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------
def _flat_dim(observation_space: spaces.Space) -> int:
    if isinstance(observation_space, spaces.Dict):
        return sum(int(torch.tensor(s.shape).prod().item()) for s in observation_space.spaces.values())
    if isinstance(observation_space, spaces.Box):
        return int(torch.tensor(observation_space.shape).prod().item())
    raise TypeError(f"不支持的观测空间类型：{type(observation_space)}")


def _to_flat_tensor(observations) -> torch.Tensor:
    if isinstance(observations, dict):
        # Dict 观测：按 key 排序拼接（与 godot_rl 的 lod_to_dol 顺序一致）
        tensors = [observations[k] for k in sorted(observations.keys())]
        return torch.cat([t.reshape(t.shape[0], -1) if t.dim() > 1 else t for t in tensors], dim=-1)
    if isinstance(observations, torch.Tensor):
        return observations.reshape(observations.shape[0], -1) if observations.dim() > 1 else observations
    return torch.as_tensor(observations, dtype=torch.float32)


def _resize_last_dim(x: torch.Tensor, target: int) -> torch.Tensor:
    cur = x.shape[-1]
    if cur == target:
        return x
    if cur > target:
        return x[..., :target]
    pad = torch.zeros(*x.shape[:-1], target - cur, dtype=x.dtype, device=x.device)
    return torch.cat([x, pad], dim=-1)
