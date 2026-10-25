# Aigo S60 (RK3588) 双 Realtek 交换机适配文档

> **目标内核**: mainline 6.18.y (recovery)
> **参考内核**: Rockchip 官方 6.1 BSP
> **硬件**: Aigo S60 — RK3588 + 2 颗 Realtek 交换芯片 (RTL8365MB / RTL8367RB-VB)
> **最终状态**: 10 个用户端口 (eth2–eth11) + 2 个 DSA master (eth0/eth1) 全部正常，DHCP/上网均可用

本文档记录把官方 6.1 BSP 的双交换机拓扑移植到 mainline 6.18 内核时遇到的所有问题、根因分析和修复方案，便于后续在其他内核版本上复现。

---

## 1. 硬件拓扑

```
                      ┌─────────────── RK3588 ───────────────┐
                      │                                      │
   gmac1 (fe1c0000) ──┤── RGMII ── switch0 (RTL8365MB)       │
   gmac0 (fe1b0000) ──┤── RGMII ── switch1 (RTL8367RB-VB)    │
                      │                                      │
                      │  SMI: gpio4 bit-bang (mdc/mdio)      │
                      │  reset: gpio4 (各自独立 reset-gpio)  │
                      └──────────────────────────────────────┘

switch0: 5 个用户口 (port 0-4) + 1 个 CPU 口 (port 7, extint 2)
         → eth0 (master) / eth2-eth6 (slave)

switch1: 5 个用户口 (port 0-4) + 1 个 CPU 口 (port 6, extint 1)
         → eth1 (master) / eth7-eth11 (slave)
```

### 官方 6.1 BSP 的实现方式
- switch0: `compatible = "realtek,rtl8365mb"`，上游开源 `rtl8365mb` 驱动
- switch1: `compatible = "realtek,rtl8367RB"` + `realtek,api`，**BSP 私有闭源 `rtl_api` 驱动**（源码树中不存在）
- switch1 CPU 口在官方 DT 中是 `port@16`（内部 CPU 口，仅 `rtl_api` 驱动认）

### 本方案的关键决策
- **两颗交换芯片都用上游 `rtl8365mb` 驱动**（通过 chip id 自动识别），不依赖闭源 `rtl_api`
- 在 `rtl8365mb_of_match[]` 中增加 `realtek,rtl8367rb` / `realtek,rtl8367rb-vb` compatible
- switch1 CPU 口从 `port@16` 改为 `port@6`（见 §4.3 根因分析）

---

## 2. 涉及的源文件清单

| 文件 | 改动内容 |
|------|----------|
| `arch/arm64/boot/dts/rockchip/rk3588-aigo-s60.dts` | switch0/switch1 节点、GMAC 配置、GIC/ITS 覆盖、MTL 队列 |
| `drivers/net/dsa/realtek/rtl8365mb_main.c` | compatible 增加、端口数上限、早期 RGMII 配置、BSP 物理层寄存器、寄存器 dump |
| `drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c` | `rk3588_set_to_rgmii()` php_grf 写入、`rk_dwmac_fix_reset()`、probe 中早期 `rk_gmac_powerup()` |
| `net/dsa/tag_rtl8_4.c` | `rtl8_4_read_tag()` 多交换机 device index 修复 |
| `kdev-build.sh` | cmdline 增加 `irqchip.gicv3_pseudo_nmi=0 irqchip.gicv3_nolpi=1` |

---

## 3. 问题总览与修复路线图

按修复顺序排列，每个问题标注**根因等级**：

1. **[ROOT] GIC/ITS 中断配置** — gmac0 的 SPI 227 中断不投递 → DMA 看门狗循环
2. **[ROOT] php_grf RGMII 时钟路径** — gmac0 RGMII RX 时钟未路由到 DMA → SFT_RESET 卡死
3. **[ROOT] switch1 CPU 口 extint 选错** — RGMII 走错外部接口 → gmac0 SFT_RESET 永久卡死
4. **[ROOT] DSA tag_rtl8_4 多交换机 device index** — switch1 收到的包找不到 user 口
5. **[配套] 早期 RGMII 配置 + force-link** — RX 时钟在 DMA reset 之前就要跑起来
6. **[配套] probe 中早期 powerup** — RGMII 时钟路径要在 DMA 出 reset 之前配好
7. **[配套] MTL 队列数** — TX queue 1 卡死触发 NETDEV WATCHDOG
8. **[配套] 端口自动枚举** — 固定 `label` 导致 -EEXIST 命名冲突
9. **[配套] BSP 物理层 CHIP_DEBUG 寄存器** — RGMII 驱动强度/斜率

下面逐节详述。

---

## 4. 根因分析与修复

### 4.1 GIC/ITS 中断配置（ROOT）

#### 现象
gmac0 (eth1) 的中断计数永远为 0，`dmesg` 反复打印 `Failed to reset the dma` + `NETDEV WATCHDOG`。

#### 根因
mainline 6.18 的 `rk3588.dtsi`：
- ITS 节点被标记为 `status = "disabled"`（erratum RK3588001 workaround）
- GIC 节点新增 `mbi-ranges = <424 56>`，注册了 `gic-v3-mbi` MSI domain
- ITS 节点设为 `dma-noncoherent`

而官方 6.1 BSP 的 DT：**ITS 启用、无 mbi 属性、默认 coherent**。gmac0 用的是有线 SPI 227 中断，不是 MSI，但 MBI domain 的存在会干扰中断路由。

#### 修复（DTS）
```dts
&its0 {
    status = "okay";
    dma-coherent;
};

&its1 {
    status = "okay";
    dma-coherent;
};

&gic {
    mbi-ranges = <0 0>;   /* 空范围 → mbi_init() 不注册 MSI domain */
};
```

#### 修复（cmdline，`kdev-build.sh`）
```
irqchip.gicv3_pseudo_nmi=0   /* 关闭 pseudo-NMI，避免 SPI 路由异常 */
irqchip.gicv3_nolpi=1        /* 不使用 LPI，全走有线 SPI */
```

#### 验证
修复后 eth1 IRQ 计数正常增长，无 watchdog 循环。

---

### 4.2 php_grf RGMII 时钟路径（ROOT）

#### 现象
gmac1 (switch0 侧) 一切正常；gmac0 (switch1 侧) 的 `DMA_BUS_MODE.SFT_RESET` 永远不自清，DMA 引擎永久卡在 reset 状态。

#### 根因
RK3588 有两个 GRF 域：
- **sys_grf** — gmac1 的 RGMII 时钟路径走这里
- **php_grf** — gmac0 的 RGMII 时钟路径**额外**走这里（PHP = PCIe/HP 子系统）

mainline 6.18 的 `rk3588_set_to_rgmii()` **只写 sys_grf**（CON7/CON8/CON9），不写 php_grf。官方 6.1 BSP 的同名函数**同时写 sys_grf 和 php_grf**（CON0 @ 0x08, CLK_CON1 @ 0x70）。

结果：gmac0 的 RGMII RX 时钟根本没到达 DMA block，DMA reset 自然无法完成。

#### 修复（`dwmac-rk.c`）

在 `rk3588_set_to_rgmii()` 末尾增加 php_grf 写入：

```c
/* php_grf */
#define RK3588_GRF_GMAC_CON0    0x0008
#define RK3588_GRF_CLK_CON1     0x0070

static void rk3588_set_to_rgmii(struct rk_priv_data *bsp_priv,
                                int tx_delay, int rx_delay)
{
    u32 offset_con, id = bsp_priv->id;
    u32 php_con0, php_clk_con1;

    /* sys_grf: 原有逻辑不变 */
    offset_con = id == 1 ? RK3588_GRF_GMAC_CON9 : RK3588_GRF_GMAC_CON8;
    regmap_write(bsp_priv->grf, RK3588_GRF_GMAC_CON7,
                 RK3588_GMAC_RXCLK_DLY_ENABLE(id) |
                 RK3588_GMAC_TXCLK_DLY_ENABLE(id));
    regmap_write(bsp_priv->grf, offset_con,
                 RK3588_GMAC_CLK_RX_DL_CFG(rx_delay) |
                 RK3588_GMAC_CLK_TX_DL_CFG(tx_delay));

    /* php_grf: 新增 —— gmac0 的 RGMII 时钟路径必须经过 php_grf */
    php_con0 = BIT(id * 6 + 3)   /* RX delay enable value */
             | BIT(id * 6 + 19)  /* RX delay enable WE */
             | BIT(id * 6 + 20)  /* TX delay enable WE (clear) */
             | BIT(id * 6 + 21); /* mode bit WE (clear) */
    php_clk_con1 = BIT(id * 5 + 16); /* 清 CRU mode 位 */

    regmap_write(bsp_priv->php_grf, RK3588_GRF_GMAC_CON0, php_con0);
    regmap_write(bsp_priv->php_grf, RK3588_GRF_CLK_CON1, php_clk_con1);
}
```

同时在 `rk_priv_data` 结构体增加 `php_grf` 字段，`rk_gmac_setup()` 中通过 `syscon_regmap_lookup_by_phandle()` 获取（当 `ops->php_grf_required = true` 时）。

#### php_grf 寄存器位布局（从官方 BSP 反汇编解码）
| 寄存器 | 位 | 含义 |
|--------|-----|------|
| CON0 (0x08) | `id*6+3` | RX delay enable **值** |
| CON0 (0x08) | `id*6+19` | RX delay enable **写使能** (value+16) |
| CON0 (0x08) | `id*6+20` | TX delay enable **写使能** (清除 TX delay) |
| CON0 (0x08) | `id*6+21` | mode bit **写使能** (清除 mode) |
| CLK_CON1 (0x70) | `id*5` | CRU mode 位**值** |
| CLK_CON1 (0x70) | `id*5+16` | CRU mode 位**写使能** |

#### 验证
两台机器均显示 `php_grf CON0=0x00000208, CLK_CON1=0x00000210`，与官方 BSP 完全一致。

---

### 4.3 switch1 CPU 口 extint 选错（ROOT — 最关键）

#### 现象
即使修了 §4.1 和 §4.2，gmac0 的 SFT_RESET 仍然卡死。switch1 用 `port@7` (extint 2) 时，DMA_BUS_MODE 一直为 `0x00000001`（SFT_RESET 位不自清）。

#### 根因
**板子的 RGMII 走线物理上把 switch1 连到了 extint 1，不是 extint 2。**

证据链：
1. 官方 6.1 BSP 的 `rtl8367b.c` 中，RTL8367R_VB 的 `cpu_port=5 → extif 1`
2. BSP `extif 1` 对应 rtl8365mb 驱动的 **extint 1**（port 6），不是 extint 2（port 7）
3. RTL8367RB-VB 的 extint 1 **支持 RGMII**（与 RTL8367S 不同，后者 extint 1 只支持 SGMII/HSGMII）
4. 用 extint 1 (port@6) 后，gmac0 DMA_BUS_MODE 立即自清到 `0x00000000`，零 SFT_RESET 错误

#### 修复（DTS）

switch1 的 CPU 口从 `port@7` 改为 `port@6`：

```dts
switch1: switch1 {
    compatible = "realtek,rtl8367rb";
    /* ... SMI gpio ... */
    dsa,member = <1 1>;   /* tree 1, index 1 */

    ports {
        /* port@0 ~ port@4: 用户口，phy-handle 指向内部 PHY */

        port@6 {              /* ← 原来是 port@7 */
            reg = <6>;
            ethernet = <&gmac0>;
            phy-mode = "rgmii";
            fixed-link {
                speed = <1000>;
                full-duplex;
            };
        };
    };
};
```

> **注意**: switch0 的 CPU 口仍然是 `port@7` (extint 2)，因为 RTL8365MB/RTL8367S 的 extint 2 才支持 RGMII。两颗芯片的 extint 能力不同，不能照搬。

#### extint 与 port 的映射关系（rtl8365mb 驱动）
| extint id | port | 对应芯片 |
|-----------|------|----------|
| 0 | port@5 | RTL8365MB |
| 1 | port@6 | RTL8367RB-VB (本板 switch1) |
| 2 | port@7 | RTL8365MB / RTL8367S (本板 switch0) |

---

### 4.4 DSA tag_rtl8_4 多交换机 device index（ROOT）

#### 现象
switch1 的端口能枚举出来，插线有 link，但 DHCP 不通。`dmesg` 反复打印：
```
could not find user for port 3
could not find user for port 4
```

#### 根因
`rtl8_4_read_tag()` 中 `dsa_conduit_find_user()` 的 **device index 硬编码为 0**：

```c
/* 原始 buggy 代码 */
skb->dev = dsa_conduit_find_user(dev, 0, port);  /* ← 永远找 switch0 */
```

RTL8_4 tag 格式只有源端口号（4 bit），**没有 switch device index 字段**。在单交换机场景下硬编码 0 没问题，但本板有两棵 DSA 树：
- switch0: `dsa,member` 缺省 = `<0 0>`，`ds->index = 0`
- switch1: `dsa,member = <1 1>`，`ds->index = 1`

switch1 收到的包应当用 `device=1` 查找 user 口，但硬编码 0 导致去 switch0 的端口表里找 port 3/4，自然找不到。

#### 修复（`net/dsa/tag_rtl8_4.c`）

从 conduit netdev 的 `dsa_ptr` 取 CPU port，再取其 `ds->index`：

```c
static int rtl8_4_read_tag(struct sk_buff *skb, struct net_device *dev,
                           void *tag)
{
    /* ... 解析 etype/proto/reason/port ... */

    /* RTL8_4 tag 不携带 switch device index，只有源端口号。
     * 在多交换机场景下，conduit netdev (eth0/eth1) 唯一标识了
     * 交换机。用 CPU port 的 ds->index 来查找正确的 user 口。 */
    struct dsa_port *cpu_dp = dev->dsa_ptr;

    skb->dev = dsa_conduit_find_user(dev, cpu_dp->ds->index, port);
    if (!skb->dev) {
        dev_warn_ratelimited(&dev->dev,
                             "could not find user for port %d\n", port);
        return -ENOENT;
    }
    /* ... */
}
```

#### 为什么 conduit 能唯一标识交换机
每个交换机有自己的 CPU conduit（switch0 → eth0, switch1 → eth1），`dev` 就是收到包的那个 conduit。`dev->dsa_ptr` 指向该 conduit 的 CPU dsa_port，`cpu_dp->ds` 就是这个 conduit 所属的 dsa_switch，`ds->index` 就是正确的 device index。

---

### 4.5 早期 RGMII 配置 + force-link（配套）

#### 问题
stmmac 在 `stmmac_open()` → `stmmac_hw_setup()` → `stmmac_init_dma_engine()` 中会做 DMA 软件复位（`DMA_BUS_MODE.SFT_RESET`），该复位**需要 RGMII RX 时钟在跑**才能自清。

但上游 `rtl8365mb` 驱动把 RGMII extint 配置延迟到 `phylink_mac_config()`，这在 `stmmac_open()` **之后**才调用——太晚了。

#### 修复（`rtl8365mb_main.c` 的 `rtl8365mb_setup()`）

在 DSA probe 阶段（conduit netdev 打开之前）就配置 CPU 口的 RGMII extint 并强制 link up：

```c
static int rtl8365mb_setup(struct dsa_switch *ds)
{
    /* ... 常规初始化 ... */

    dsa_switch_for_each_cpu_port(dp, ds) {
        phy_interface_t interface;
        int err;

        err = of_get_phy_mode(dp->dn, &interface);
        if (err || !phy_interface_mode_is_rgmii(interface))
            continue;

        /* 1. 配置 RGMII extint（设置模式 + TX/RX delay） */
        err = rtl8365mb_ext_config_rgmii(priv, dp->index, interface);

        /* 2. 强制 CPU 口 link up @ 1Gbps/full-duplex
         *    使交换芯片立即开始输出 RGMII RX 时钟 */
        err = rtl8365mb_ext_config_forcemode(priv, dp->index, true,
                                             SPEED_1000, DUPLEX_FULL,
                                             false, false);

        /* 3. BSP 物理层寄存器（见 §4.9） */
    }
    /* ... */
}
```

这镜像了官方 BSP `rtl_api` 驱动的行为——它在 GMAC 打开之前就配好了交换芯片的 CPU 口 RGMII。

---

### 4.6 probe 中早期 rk_gmac_powerup（配套）

#### 问题
mainline 6.18 的 `rk_gmac_probe()` 通过 `plat_dat->init` 回调调用 `rk_gmac_powerup()`，而 `init` 是在 `stmmac_dvr_probe()` 中 `reset_control_deassert()` **之后**才调用的。

官方 6.1 BSP 在 `rk_gmac_probe()` 中**直接调用** `rk_gmac_powerup()`，在 `stmmac_dvr_probe()` **之前**。这保证 RGMII 时钟路径（`set_to_rgmii()` 写 sys_grf + php_grf）在 DMA block 出 reset 之前就配好了。

#### 修复（`dwmac-rk.c` 的 `rk_gmac_probe()`）

```c
static int rk_gmac_probe(struct platform_device *pdev)
{
    /* ... plat_dat 设置 ... */
    plat_dat->fix_soc_reset = rk_dwmac_fix_reset;
    plat_dat->bsp_priv = rk_gmac_setup(pdev, plat_dat, data);
    ret = rk_gmac_clk_init(plat_dat);

    /* ↓↓↓ 新增：在 stmmac_dvr_probe() 之前 powerup ↓↓↓ */
    ret = rk_gmac_powerup(plat_dat->bsp_priv);
    if (ret)
        return ret;

    return devm_stmmac_pltfr_probe(pdev, plat_dat, &stmmac_res);
}
```

`rk_gmac_powerup()` 是幂等的：`gmac_clk_enable()` 检查 `clk_enabled` 标志，`set_to_rgmii()` 只是重写相同的 GRF 值。后续 `plat_dat->init` 再次调用不会有副作用。

---

### 4.7 rk_dwmac_fix_reset（配套）

#### 问题
即使 RGMII 时钟已配好，某些时序场景下 DMA SFT_RESET 仍可能不自清。需要一个更可靠的 reset 路径。

#### 修复（`dwmac-rk.c`）

通过 `plat_dat->fix_soc_reset` 注册自定义 reset 函数，在标准 DMA 软复位之前先脉冲 CRU 硬件 reset：

```c
static int rk_dwmac_fix_reset(struct stmmac_priv *priv)
{
    struct plat_stmmacenet_data *plat = priv->plat;
    void __iomem *ioaddr = priv->ioaddr;
    u32 value;
    int ret;

    /* 脉冲 CRU 硬件 reset (SRST_A_GMACx) */
    if (plat->stmmac_rst && !IS_ERR(plat->stmmac_rst)) {
        reset_control_assert(plat->stmmac_rst);
        udelay(100);
        reset_control_deassert(plat->stmmac_rst);
        usleep_range(2000, 4000);
    }

    /* 标准 DMA 软复位 */
    value = readl(ioaddr + DMA_BUS_MODE);
    value |= DMA_BUS_MODE_SFT_RESET;
    writel(value, ioaddr + DMA_BUS_MODE);

    ret = readl_poll_timeout(ioaddr + DMA_BUS_MODE, value,
                             !(value & DMA_BUS_MODE_SFT_RESET),
                             10000, 1000000);
    if (ret)
        netdev_warn(priv->dev, "DMA SFT_RESET did not self-clear\n");
    return ret;
}
```

需要在 `rk_priv_data` 结构体中增加 `stmmac_rst` 字段，在 `rk_gmac_setup()` 中保存 `plat->stmmac_rst`。

---

### 4.8 MTL 队列数 + 端口自动枚举（配套）

#### MTL 队列
继承的 `rk3588.dtsi` 配了 2 个 TX 队列，gmac0 的 TX queue 1 会卡死触发 watchdog。覆盖为 1 个队列：

```dts
&gmac0_mtl_rx_setup { snps,rx-queues-to-use = <1>; };
&gmac0_mtl_tx_setup { snps,tx-queues-to-use = <1>; };
&gmac1_mtl_rx_setup { snps,rx-queues-to-use = <1>; };
&gmac1_mtl_tx_setup { snps,tx-queues-to-use = <1>; };
```

#### 端口自动枚举
**不要**在 port 节点中写 `label = "eth2"` 之类的固定名，否则两棵 DSA 树的端口会撞名 (-EEXIST)。去掉 `label` 后内核自动按枚举顺序命名：GMAC master 先得 `eth0`/`eth1`，switch0 的 slave 得 `eth2`–`eth6`，switch1 的 slave 得 `eth7`–`eth11`。

---

### 4.9 BSP 物理层 CHIP_DEBUG 寄存器（配套）

#### 问题
上游 `rtl8365mb` 不写 CHIP_DEBUG 寄存器，但官方 BSP `rtl8367b.c` 的 `rtl8367b_extif_set_mode()` 会写，配置 RGMII 物理层驱动强度和斜率。

#### 修复（`rtl8365mb_main.c` 的 `rtl8365mb_setup()`）

动态检测 CPU 口用的 extint id，写对应的 CHIP_DEBUG 寄存器：

**extint 0 或 1** → 写 CHIP_DEBUG0 (0x1303) + CHIP_DEBUG1 (0x1304)：
```c
/* CHIP_DEBUG0: SEL33(id), DRI_RG(id), 清 DRI(id), 清 SLR(id) */
dbg0 |= BIT(8 + id);   /* SEL33 */
dbg0 |= BIT(5 + id);   /* DRI_RG */
dbg0 &= ~BIT(3 + id);  /* 清 DRI */
dbg0 &= ~BIT(id);      /* 清 SLR */

/* CHIP_DEBUG1: DN(id)=7, DP(id)=7 */
dbg1 |= (7 << (4 + id * 8));  /* DN=7 */
dbg1 |= (7 << (id * 8));      /* DP=7 */
```

**extint 2** → 写 CHIP_DEBUG2 (0x13E2)：
```c
dbg2 |= BIT(2);       /* DRI_EXT2_RG */
dbg2 &= ~BIT(1);      /* 清 DRI_EXT2 */
dbg2 &= ~BIT(0);      /* SLR_EXT2 */
dbg2 |= (7 << 6);     /* RG2_DN=7 */
dbg2 |= (7 << 3);     /* RG2_DP=7 */
```

> **注意**: `TOP_CON0` 的 `MAC7_SEL_EXT1` 和 `SDS1_DISABLE` 写入**仅适用于 RTL8367S_VB** (chip_ver 0x00A0)，**不适用于** RTL8367RB-VB (chip_ver 0x0020)。不要照搬。

---

## 5. DTS 完整结构参考

### switch0（RTL8365MB，gmac1，extint 2）
```dts
switch0: switch0 {
    compatible = "realtek,rtl8365mb";
    mdc-gpios = <&gpio4 RK_PA6 GPIO_ACTIVE_HIGH>;
    mdio-gpios = <&gpio4 RK_PA7 GPIO_ACTIVE_HIGH>;
    reset-gpios = <&gpio4 RK_PC0 GPIO_ACTIVE_LOW>;
    /* 无 dsa,member → 默认 <0 0> */

    ports {
        #address-cells = <1>;
        #size-cells = <0>;

        port@0 { reg = <0>; phy-handle = <&sw0_phy0>; };
        port@1 { reg = <1>; phy-handle = <&sw0_phy1>; };
        port@2 { reg = <2>; phy-handle = <&sw0_phy2>; };
        port@3 { reg = <3>; phy-handle = <&sw0_phy3>; };
        port@4 { reg = <4>; phy-handle = <&sw0_phy4>; };

        port@7 {                /* CPU 口, extint 2 */
            reg = <7>;
            ethernet = <&gmac1>;
            phy-mode = "rgmii";
            fixed-link { speed = <1000>; full-duplex; };
        };
    };

    mdio {
        compatible = "realtek,smi-mdio";
        #address-cells = <1>;
        #size-cells = <0>;
        sw0_phy0: ethernet-phy@0 { reg = <0>; };
        sw0_phy1: ethernet-phy@1 { reg = <1>; };
        sw0_phy2: ethernet-phy@2 { reg = <2>; };
        sw0_phy3: ethernet-phy@3 { reg = <3>; };
        sw0_phy4: ethernet-phy@4 { reg = <4>; };
    };
};
```

### switch1（RTL8367RB-VB，gmac0，extint 1）
```dts
switch1: switch1 {
    compatible = "realtek,rtl8367rb";
    mdc-gpios = <&gpio4 RK_PA4 GPIO_ACTIVE_HIGH>;
    mdio-gpios = <&gpio4 RK_PA5 GPIO_ACTIVE_HIGH>;
    reset-gpios = <&gpio4 RK_PB7 GPIO_ACTIVE_LOW>;
    dsa,member = <1 1>;      /* tree 1, index 1 */

    ports {
        #address-cells = <1>;
        #size-cells = <0>;

        port@0 { reg = <0>; phy-handle = <&sw1_phy0>; };
        port@1 { reg = <1>; phy-handle = <&sw1_phy1>; };
        port@2 { reg = <2>; phy-handle = <&sw1_phy2>; };
        port@3 { reg = <3>; phy-handle = <&sw1_phy3>; };
        port@4 { reg = <4>; phy-handle = <&sw1_phy4>; };

        port@6 {                /* CPU 口, extint 1 ← 关键！不是 port@7 */
            reg = <6>;
            ethernet = <&gmac0>;
            phy-mode = "rgmii";
            fixed-link { speed = <1000>; full-duplex; };
        };
    };

    mdio {
        compatible = "realtek,smi-mdio";
        #address-cells = <1>;
        #size-cells = <0>;
        sw1_phy0: ethernet-phy@0 { reg = <0>; };
        sw1_phy1: ethernet-phy@1 { reg = <1>; };
        sw1_phy2: ethernet-phy@2 { reg = <2>; };
        sw1_phy3: ethernet-phy@3 { reg = <3>; };
        sw1_phy4: ethernet-phy@4 { reg = <4>; };
    };
};
```

### GMAC 节点
```dts
&gmac0 {   /* switch1 CPU 口 */
    clock_in_out = "output";
    phy-mode = "rgmii";
    tx_delay = <0x4f>;
    rx_delay = <0x0f>;
    pinctrl-0 = <&gmac0_tx_bus2 &gmac0_rx_bus2
                 &gmac0_rgmii_clk &gmac0_rgmii_bus>;
    status = "okay";
    fixed-link { speed = <1000>; full-duplex; };
};

&gmac1 {   /* switch0 CPU 口 */
    clock_in_out = "output";
    phy-mode = "rgmii";
    tx_delay = <0x4f>;
    rx_delay = <0x0f>;
    pinctrl-0 = <&gmac1_tx_bus2 &gmac1_rx_bus2
                 &gmac1_rgmii_clk &gmac1_rgmii_bus>;
    status = "okay";
    fixed-link { speed = <1000>; full-duplex; };
};
```

---

## 6. 驱动改动细节

### 6.1 rtl8365mb_main.c

#### compatible 增加
```c
static const struct of_device_id rtl8365mb_of_match[] = {
    { .compatible = "realtek,rtl8365mb",     .data = &rtl8365mb_variant, },
    { .compatible = "realtek,rtl8367rb",     .data = &rtl8365mb_variant, },
    { .compatible = "realtek,rtl8367rb-vb",  .data = &rtl8365mb_variant, },
    { /* sentinel */ },
};
```

#### 端口数上限
```c
#define RTL8365MB_MAX_NUM_PORTS    20    /* 原值 11，port@16 会被拒 */
```

#### rtl8365mb_setup() 中的早期 RGMII 配置
对每个 CPU port：
1. `of_get_phy_mode()` 获取 phy-mode
2. `rtl8365mb_ext_config_rgmii()` 配置 extint RGMII 模式 + delay
3. `rtl8365mb_ext_config_forcemode()` 强制 1Gbps/full-duplex link up
4. 写 CHIP_DEBUG0/1 或 CHIP_DEBUG2（按 extint id 分支）

### 6.2 tag_rtl8_4.c
见 §4.4，核心改动一行：`dsa_conduit_find_user(dev, cpu_dp->ds->index, port)`。

### 6.3 dwmac-rk.c
| 函数 | 改动 |
|------|------|
| `rk3588_set_to_rgmii()` | 增加 php_grf CON0 + CLK_CON1 写入 |
| `rk_dwmac_fix_reset()` | 新增：CRU 硬 reset + 标准 DMA SFT_RESET |
| `rk_gmac_probe()` | 新增：`devm_stmmac_pltfr_probe()` 之前调用 `rk_gmac_powerup()` |
| `rk_priv_data` | 新增 `stmmac_rst` 字段 |
| `rk_gmac_setup()` | 保存 `plat->stmmac_rst` |
| `rk3588_ops` | `.php_grf_required = true` |

---

## 7. 构建与部署

### 构建
```bash
./kdev-build.sh
```
构建脚本会把内核+initramfs 打包成 `release/recovery.img`。cmdline 中必须包含：
```
irqchip.gicv3_pseudo_nmi=0 irqchip.gicv3_nolpi=1
```

### 部署
- 刷机工具更新 mmcblk0p4 上的 kernel+dtb，但**保留**已有的 `/recovery.conf`
- cmdline 变更需要手动更新 p4 的 `recovery.conf`
- **传输文件必须用 `cat > file`**，不能用 BusyBox `cp`（会提示 "overwrite?" 阻塞 SSH 管道导致文件损坏变砖）

### 验证
```bash
ip -br a
# 应看到: eth0/eth1 (UP, 无 IP), eth2-eth11 (DOWN/UP),
#         连线的口有 DHCP IP

dmesg | grep -E "SFT_RESET|could not find user|Link is Up|early RGMII"
# 应无 SFT_RESET 错误, 无 "could not find user", 两个 switch 均 Link Up 1Gbps
```

---

## 8. 调试工具与技巧

### 寄存器读写工具
交叉编译静态 `rdreg`/`wrreg`（aarch64），通过 `/dev/mem` 访问寄存器：
```bash
ssh root@box 'cat > /root/rdreg' < rdreg
./rdreg <phys_addr> [count]
./wrreg <phys_addr> <0xFFFFNNNN>   # 高16位=写使能掩码, 低16位=值
```

> **注意**: GRF/IOC 寄存器必须用写使能格式（`0xFFFFNNNN`），直接写 `0xNNNN` 会被静默忽略。两台机器偶尔会在写 gmac0 寄存器时崩溃需要物理断电。

### 关键寄存器速查
| 寄存器 | 地址 | 正常值 |
|--------|------|--------|
| gmac0 DMA_BUS_MODE | 0xfe1b1000 | 0x00000000 (reset 完成后) |
| gmac1 DMA_BUS_MODE | 0xfe1c1000 | 0x00000000 |
| php_grf CON0 | 0xfd5b0008 | 0x00000208 |
| php_grf CLK_CON1 | 0xfd5b0070 | 0x00000210 |

### dmesg 关键字
- `early RGMII config for CPU port` — 早期 RGMII 配置成功
- `early force-link 1Gbps/full on CPU port` — force-link 成功
- `BSP extint N: CHIP_DEBUG` — 物理层寄存器已写
- `Link is Up - 1Gbps/Full` — 两个 switch 都应出现
- **不应出现**: `SFT_RESET did not self-clear`、`could not find user for port`、`NETDEV WATCHDOG`

---

## 9. 移植到其他内核版本的检查清单

按顺序确认/修改：

- [ ] **GIC/ITS**: 检查目标内核 `rk3588.dtsi` 的 ITS 状态和 mbi-ranges，按 §4.1 覆盖
- [ ] **php_grf**: 检查 `rk3588_set_to_rgmii()` 是否写 php_grf，按 §4.2 补充
- [ ] **probe 时序**: 检查 `rk_gmac_powerup()` 是否在 `stmmac_dvr_probe()` 之前调用，按 §4.6 调整
- [ ] **fix_soc_reset**: 注册 `rk_dwmac_fix_reset()`，按 §4.7
- [ ] **switch1 CPU 口**: 确认用 `port@6` (extint 1)，不是 `port@7` (extint 2)，按 §4.3
- [ ] **tag_rtl8_4**: 检查 `rtl8_4_read_tag()` 是否用 `cpu_dp->ds->index`，按 §4.4
- [ ] **早期 RGMII 配置**: 在 `rtl8365mb_setup()` 中配置 CPU 口 RGMII + force-link，按 §4.5
- [ ] **CHIP_DEBUG 寄存器**: 按 extint id 写对应寄存器，按 §4.9
- [ ] **MTL 队列**: 覆盖为 1 个队列，按 §4.8
- [ ] **端口命名**: 去掉 `label` 属性让内核自动枚举，按 §4.8
- [ ] **compatible**: 在 `rtl8365mb_of_match[]` 加 `realtek,rtl8367rb` / `realtek,rtl8367rb-vb`
- [ ] **端口上限**: `RTL8365MB_MAX_NUM_PORTS` ≥ 20
- [ ] **cmdline**: 加 `irqchip.gicv3_pseudo_nmi=0 irqchip.gicv3_nolpi=1`
- [ ] **Kconfig**: 启用 `NET_DSA_REALTEK_RTL8365MB` 和 `NET_DSA_TAG_RTL8_4`

---

## 10. 已验证的最终状态

```
lo          UNKNOWN   127.0.0.1/8
eth0        UP        (DSA master, switch0, 无 IP)
eth1        UP        (DSA master, switch1, 无 IP)
eth2@eth0   LOWERLAYERDOWN
eth3@eth0   LOWERLAYERDOWN
eth4@eth0   UP        192.168.33.40/24   ← DHCP OK
eth5@eth0   LOWERLAYERDOWN
eth6@eth0   DOWN
eth7@eth1   LOWERLAYERDOWN
eth8@eth1   LOWERLAYERDOWN
eth9@eth1   LOWERLAYERDOWN
eth10@eth1  DOWN
eth11@eth1  UP        192.168.33.42/24   ← DHCP OK
```

- 两个 GMAC master (eth0/eth1) 均 UP
- 10 个用户端口 (eth2-eth11) 全部枚举
- 连线的端口 (eth4, eth11) 均获得 DHCP IP，可上网
- 零 SFT_RESET 错误，零 "could not find user" 错误
- 两台机器 php_grf 寄存器值与官方 BSP 完全一致
