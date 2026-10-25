# Aigo S60 (RK3588) Recovery 内核适配检测报告

> **检测日期**: 2026-10-26
> **检测目标**: 192.168.33.50 (recovery 模式)
> **内核版本**: 6.18.57-kdev #186 SMP PREEMPT_DYNAMIC
> **设备型号**: Aigo S60 (rockchip,rk3588-aigo-s60)
> **eMMC**: AJTD4R 14.6 GiB (mmcblk0, 8 partitions + 2 boot + rpmb)

---

## 一、总体结论

| 项目 | 状态 |
|------|------|
| 内核引导 | ✅ 正常，8 核全启动，无 panic |
| 双交换机 | ✅ switch0 (RTL8367S) + switch1 (RTL8367RB-VB) 均正常 |
| 网络命名 | ✅ end0/end1 (master) + eth1-eth10 (slave，按丝印) |
| MAC 地址 | ✅ 12 个接口全部固定，02:00:00:00:00:01-0c |
| DHCP | ✅ eth5 (192.168.33.50) + eth10 (192.168.33.47) 均获取 IP |
| 网络连通 | ✅ ping 网关 192.168.33.1 正常 (0% loss) |
| 温控 | ✅ 7 个 thermal zone + pwm-fan cooling device 正常 |
| 电压调节器 | ✅ 34 个 regulator 全部注册，含 vdd_npu/big0/big1 |
| eMMC | ✅ HS400 Enhanced Strobe，CQHCI 正常 |
| LED | ✅ work-led (heartbeat) + net-led |
| PMIC | ✅ RK806 via SPI2，pwrkey 正常 |
| 延迟探测 | ✅ 零 deferred probe |
| **遗留警告** | ⚠️ 2 条（详见 §四），均为无害项 |

---

## 二、网络状态

### 接口列表
```
lo          127.0.0.1/8
end0        UP    (DSA master, switch1, fe1b0000.ethernet)
end1        UP    (DSA master, switch0, fe1c0000.ethernet)
eth1@end1   LOWERLAYERDOWN  (switch0 port0)
eth2@end1   LOWERLAYERDOWN  (switch0 port1)
eth3@end1   LOWERLAYERDOWN  (switch0 port2)
eth4@end1   LOWERLAYERDOWN  (switch0 port3)
eth5@end1   UP    192.168.33.50/24  ← DHCP OK (连线)
eth6@end0   LOWERLAYERDOWN  (switch1 port0)
eth7@end0   LOWERLAYERDOWN  (switch1 port1)
eth8@end0   LOWERLAYERDOWN  (switch1 port2)
eth9@end0   LOWERLAYERDOWN  (switch1 port3)
eth10@end0  UP    192.168.33.47/24  ← DHCP OK (连线)
br0         192.168.98.1/24  (recovery 管理 LAN)
```

### MAC 地址验证
全部 12 个接口 MAC 地址与 DTS `local-mac-address` 一致：
```
end0:  02:00:00:00:00:01    eth1:  02:00:00:00:00:03
end1:  02:00:00:00:00:02    eth2:  02:00:00:00:00:04
                            eth3:  02:00:00:00:00:05
                            eth4:  02:00:00:00:00:06
                            eth5:  02:00:00:00:00:07
                            eth6:  02:00:00:00:00:08
                            eth7:  02:00:00:00:00:09
                            eth8:  02:00:00:00:00:0a
                            eth9:  02:00:00:00:00:0b
                            eth10: 02:00:00:00:00:0c
```

### 交换机链路状态
```
switch0: found an RTL8367S switch
  CPU port 7 (extint 2): Link is Up - 1Gbps/Full
  eth5: Link is Up - 1Gbps/Full - flow control rx/tx

switch1: found an RTL8367RB-VB switch
  CPU port 6 (extint 1): Link is Up - 1Gbps/Full
  eth10: Link is Up - 1Gbps/Full - flow control rx/tx
```

### DMA / 中断
- 零 `SFT_RESET did not self-clear` 错误
- 零 `could not find user for port` 错误
- �零 `NETDEV WATCHDOG` 错误
- 两个 GMAC 均 `Link is Up - 1Gbps/Full`

---

## 三、硬件子系统状态

### 温控
```
thermal_zone0: package-thermal     31.5°C
thermal_zone1: bigcore0-thermal    31.5°C
thermal_zone2: bigcore2-thermal    31.5°C
thermal_zone3: littlecore-thermal  32.4°C
thermal_zone4: center-thermal      31.5°C
thermal_zone5: gpu-thermal         31.5°C
thermal_zone6: npu-thermal         31.5°C
```

### 风扇 (pwm-fan)
```
hwmon7: pwmfan
pwm1: 0 (当前停转，温度低)
pwm1_enable: 1 (内核自动控制)
cooling_device0: pwm-fan  cur_state=0  max_state=5
cooling_device1: cpufreq-cpu0  cur_state=0  max_state=6
cooling_device2: cpufreq-cpu1  cur_state=0  max_state=4
cooling_device3: cpufreq-cpu6  cur_state=0  max_state=6
```
pwm-fan 使用 pwm14 (pwm@febf0020)，probe 返回 0 成功。

### 电压调节器
关键 regulator 全部正常检测：
```
fan53555-regulator 0-0042: FAN53555 Option[10] Rev[1] Detected!  (vdd_cpu_big0_s0)
fan53555-regulator 0-0043: FAN53555 Option[10] Rev[1] Detected!  (vdd_cpu_big1_s0)
fan53555-regulator 2-0042: FAN53555 Option[10] Rev[1] Detected!  (vdd_npu_s0)
```
共 34 个 regulator 注册。**fan53555 ETIMEDOUT 错误已消除**（i2c0/i2c2 pinctrl 修正后）。

### LED
```
/sys/class/leds/
  work-led   (gpio1 PA1, heartbeat trigger)
  net-led    (gpio1 PA0)
  mmc0::     (eMMC activity, 来自 dtsi 默认)
```
**LED deferred probe 错误已消除**（从 nca9555 I2C 扩展器改为 gpio1 直接驱动后）。

### eMMC
```
mmc0: SDHCI controller fe2e0000.mmc using ADMA
mmc0: new HS400 Enhanced strobe MMC card at address 0001
mmcblk0: mmc0:0001 AJTD4R 14.6 GiB
  p1 p2 p3 p4 p5 p6 p7 p8
mmcblk0boot0: 4.00 MiB
mmcblk0boot1: 4.00 MiB
mmcblk0rpmb:  4.00 MiB
```

### CPU
```
8 CPUs: 4x Cortex-A55 (0.4-1.0GHz) + 4x Cortex-A76 (0.4-1.2GHz)
当前频率: 1008000 / 1200000
GICv3: 480 SPIs, MBI range [0:-1] (已禁用)
```

### PMIC
```
RK806 via SPI2 (feb20000.spi)
rk805-pwrkey 正常注册为 input0
```

---

## 四、遗留警告分析

### 警告 1: DRM "No available vop found"
```
[    1.671695] rockchip-drm display-subsystem: *ERROR* No available vop found for display-subsystem.
```

**分析**：
- `display-subsystem` 节点在 `rk3588-base.dtsi` 中定义，引用 `ports = <&vop_out>`
- 我们已将 `&vop` 和 `&vop_mmu` 设为 `status = "disabled"`（headless recovery 不需要显示）
- VOP 被禁用后，`display-subsystem` 找不到可用的 VOP → 打印 error
- **影响**：无。recovery 模式不需要图形输出，纯串口 + SSH 操作
- **处理建议**：可在 DTS 中将 `display-subsystem` 也设为 disabled 来消除日志，但当前无害，优先级低

### 警告 2: SCMI "max-rx-timeout: 30ms"
```
[    2.023873] arm-scmi arm-scmi.3.auto: SCMI max-rx-timeout: 30ms / max-msg-size: 104bytes / max-msg: 20
[    2.026822] arm-scmi arm-scmi.3.auto: Enabling SCMI Quirk [quirk_clock_rates_triplet_out_of_spec]
```

**分析**：
- SCMI (Arm System Control and Management Interface) 是与固件通信的协议
- 这是信息性日志，不是错误。固件报告的超时/消息大小被正常解析
- quirk 是针对 Rockchip 固件非标准行为的兼容处理，正常启用
- **影响**：无
- **处理建议**：无需处理

---

## 五、本次修复历程总结

本次在 build #186 上完成的适配修复：

### 1. I2C 总线 pinctrl 修正
| 总线 | 修改前 | 修改后 | 效果 |
|------|--------|--------|------|
| i2c0 | dtsi 默认 i2c0m0 | i2c0m2 (gpio0 PD1/PD2) | vdd_cpu_big0/big1_s0 检测成功 |
| i2c2 | i2c2m4 | i2c2m0 (gpio0 PB7/PB8) | vdd_npu_s0 检测成功 |
| i2c1 | okay + vdd_npu_s0 | disabled | 消除 EINVAL 错误 |

**根因**：pinctrl 走错引脚 → I2C SDA/SCL 信号到不到芯片 → ETIMEDOUT/EINVAL

### 2. LED 适配
| 修改前 | 修改后 |
|--------|--------|
| 4 个 LED 引用 nca9555 (I2C GPIO 扩展器, i2c6 disabled) | 2 个 LED 引用 gpio1 PA0/PA1 |

**根因**：LED 引用的 I2C GPIO 扩展器在 disabled 的 i2c6 上，无法获取 GPIO → deferred probe

### 3. PWM 风扇适配
| 修改前 | 修改后 |
|--------|--------|
| pwms = <&pwm1 0 50000 0> (pwm1 disabled) | pwms = <&pwm14 0 50000 0> (pwm14 enabled, pwm14m0_pins) |

**根因**：板子风扇接在 pwm14 上，不是 pwm1。pwm1 disabled 导致 `Could not get PWM`

### 4. 端口命名与 MAC 地址
| 修改前 | 修改后 |
|--------|--------|
| GMAC: eth0/eth1 (自动枚举) | GMAC: end0/end1 (DTS label) |
| Slave: eth2-eth11 (自动枚举) | Slave: eth1-eth10 (DTS label, 按丝印) |
| MAC: 随机 | MAC: 02:00:00:00:00:01-0c 固定 |

---

## 六、与官方 6.1 BSP 对比

| 项目 | 官方 6.1 BSP | 本 recovery 内核 | 一致性 |
|------|-------------|-----------------|--------|
| switch0 驱动 | rtl8365mb | rtl8365mb | ✅ |
| switch1 驱动 | rtl_api (闭源) | rtl8365mb (开源) | ⚡ 替代方案 |
| switch1 CPU 口 | port@16 (内部) | port@6 (extint 1) | ⚡ 适配方案 |
| GMAC 命名 | end0/end1 | end0/end1 | ✅ |
| i2c0 设备 | rk8602@42 + rk8603@43 | rk8602@42 + rk8603@43 | ✅ |
| i2c2 设备 | rk8602@42 (vdd_npu_s0) | rk8602@42 (vdd_npu_s0) | ✅ |
| i2c0 pinctrl | i2c0m2 | i2c0m2 | ✅ |
| i2c2 pinctrl | i2c2m0 | i2c2m0 | ✅ |
| LED | gpio1 PA0/PA1 | gpio1 PA0/PA1 | ✅ |
| pwm-fan | pwm14, pwm14m0_pins | pwm14, pwm14m0_pins | ✅ |
| GIC/ITS | ITS enabled, no MBI | ITS enabled, mbi-ranges=<0 0> | ✅ |
| php_grf | CON0 + CLK_CON1 | CON0 + CLK_CON1 | ✅ |

---

## 七、结论

Recovery 内核 build #186 在 192.168.33.50 上运行状态**良好**：

1. **零错误**：dmesg 中无任何 probe 失败、deferred probe、DMA 错误、网络错误
2. **零告警**（除 2 条无害日志）：DRM 无 VOP 是 headless 模式预期行为，SCMI 是信息日志
3. **全功能**：双交换机 10 端口 + DHCP + 温控风扇 + 电压调节 + eMMC + LED 全部正常
4. **与官方对齐**：i2c/pinctrl/LED/pwm-fan 配置已完全对齐官方 6.1 BSP
