import Foundation

/// 物理端口分组纯函数（无 IOKit / 进程依赖，可单测）。
///
/// USB LocationID 是 32 位位图：bits 31-24 为总线（控制器）编号，bits 23-20 起每 4 bit
/// 一级端口号向低延伸（root 端口 → 一级 hub 端口 → 二级 hub 端口 …）。
/// 因此 `portKey = locationID >> 20`（总线 + 一级端口号）就是「整机物理根端口」：
/// - 直插同一物理口的设备 key 相同；
/// - 经外部 hub / 坞站级联的设备低 20 bit 不同、高 12 bit 相同，仍归同一根线。
///
/// 端口控制器（AppleHPM）数据可用时，活跃物理端口是会话的一等来源：
/// - 每个 `ConnectionActive = Yes` 的端口固定成卡。**纯 PD 充电线不枚举任何 USB/雷雳
///   设备，只靠设备聚合永远不会有它的卡**——端口会话是充电线可见的唯一途径；
/// - USB 设备会话按 `physicalPortID`（UsbIOPort 祖先链，如 "Port-USB-C@1"）挂进对应端口；
/// - 雷雳设备来自 system_profiler 的 `receptacle_N_tag`，与端口节点暂无可靠对应，仍独立成会话。
public enum PortGrouping {
    /// USB 根端口键：locationID >> 20（保留总线 8 bit + 一级端口号 4 bit）
    public static func portKey(forLocationID locationID: UInt32) -> UInt32 {
        locationID >> 20
    }

    /// 会话 id，如 "usb-0x014"（portKey 0 表示 registry 未提供 LocationID 的兜底桶）
    public static func sessionID(forPortKey portKey: UInt32) -> String {
        String(format: "usb-0x%03x", portKey)
    }

    /// 完整端口标签
    public static func portLabel(forPortKey portKey: UInt32) -> String {
        portKey == 0 ? "USB 端口（未知）" : String(format: "USB 端口 0x%03x", portKey)
    }

    // MARK: 端口控制器节点（AppleHPM）标签

    /// 端口形态名："Port-USB-C@1" → "USB-C"；"Port-MagSafe 3@1" → "MagSafe 3"。
    public static func portTypeName(fromPortID portID: String) -> String {
        var name = portID
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if name.hasPrefix("Port-") { name.removeFirst("Port-".count) }
        return name
    }

    /// 端口会话完整标签：形态 + location，如 "USB-C 端口 @1" / "MagSafe 3 端口"。
    public static func portLabel(for port: USBCPortSnapshot) -> String {
        let type = port.portType ?? portTypeName(fromPortID: port.portID)
        guard let at = port.portID.firstIndex(of: "@") else { return "\(type) 端口" }
        return "\(type) 端口 \(port.portID[at...])"
    }

    /// hub 层级深度（尽力而为）：locationID 低 20 bit 中非零 nibble 的数量。
    /// 直插根端口的设备深度 0，经一层外部 hub 的设备深度 1，以此类推。
    public static func hubDepth(forLocationID locationID: UInt32) -> Int {
        var rest = locationID & 0xF_FFFF
        var depth = 0
        while rest != 0 {
            if rest & 0xF != 0 { depth += 1 }
            rest >>= 4
        }
        return depth
    }

    // MARK: - 会话构建

    /// 从整机快照聚合线缆会话。
    ///
    /// - Parameters:
    ///   - ports: 端口控制器快照；为空（老机型 / 枚举失败）时退回纯设备聚合的旧行为。
    ///
    /// 排序规则：端口会话（按 portID）→ 无归属 USB 会话（按 portKey 升序，未知端口桶垫底）
    /// → 雷雳会话（按 receptacle 编号）；会话内设备按 (locationID, registryID) 排序，
    /// 天然按 hub 链路顺序排列。
    public static func buildSessions(usbDevices: [USBDeviceSnapshot],
                                     thunderboltDevices: [ThunderboltDeviceSnapshot],
                                     ports: [USBCPortSnapshot] = []) -> [CableSession] {
        var usbBuckets: [UInt32: [USBDeviceSnapshot]] = [:]
        for device in usbDevices {
            usbBuckets[portKey(forLocationID: device.locationID), default: []].append(device)
        }

        // 设备桶 → 物理端口：同桶设备共享同一根端口，physicalPortID 取桶内首个非空值。
        // 配得上端口节点的设备挂进端口会话；配不上的保持独立会话（旧行为）。
        var devicesByPortID: [String: [USBDeviceSnapshot]] = [:]
        var absorbedKeys: [String: Set<UInt32>] = [:]
        var orphanBuckets: [UInt32: [USBDeviceSnapshot]] = [:]
        if ports.isEmpty {
            orphanBuckets = usbBuckets
        } else {
            let portIDs = Set(ports.map(\.portID))
            for (key, devices) in usbBuckets {
                if let portID = devices.compactMap(\.physicalPortID).first, portIDs.contains(portID) {
                    devicesByPortID[portID, default: []].append(contentsOf: devices)
                    absorbedKeys[portID, default: []].insert(key)
                } else {
                    orphanBuckets[key] = devices
                }
            }
        }

        // 端口会话：活跃端口固定成卡；节点未报活跃但挂了设备的端口兜底成卡。
        // 未接线的空端口暂不出卡（空端口列表是 v2 待办，需枚举 root hub）。
        let portSessions = ports.compactMap { port -> CableSession? in
            let devices = devicesByPortID[port.portID] ?? []
            guard port.isActive || !devices.isEmpty else { return nil }
            // 评级历史延续：吸收的设备桶有非零端口键时沿用旧会话 id（如 "usb-0x141"），
            // 纯充电 / 未知端口桶改用端口节点 id（ioreg 节点名，同机稳定）。
            let legacyKey = absorbedKeys[port.portID]?.first { $0 != 0 }
            return CableSession(
                id: legacyKey.map(sessionID(forPortKey:)) ?? port.portID,
                kind: .usb,
                physicalPortID: port.portID,
                portLabel: portLabel(for: port),
                usbDevices: devices.sorted {
                    ($0.locationID, $0.registryID) < ($1.locationID, $1.registryID)
                }
            )
        }
        .sorted { ($0.physicalPortID ?? "", $0.id) < ($1.physicalPortID ?? "", $1.id) }

        let usbSessions = orphanBuckets.map { key, devices -> CableSession in
            let physicalPortID = devices.compactMap(\.physicalPortID).first
            return CableSession(
                id: sessionID(forPortKey: key),
                kind: .usb,
                portKey: key,
                physicalPortID: physicalPortID,
                portLabel: portLabel(forPortKey: key),
                usbDevices: devices.sorted {
                    ($0.locationID, $0.registryID) < ($1.locationID, $1.registryID)
                }
            )
        }
        .sorted {
            switch ($0.portKey == 0, $1.portKey == 0) {
            case (true, false): return false
            case (false, true): return true
            default: return $0.portKey! < $1.portKey!
            }
        }

        var tbBuckets: [Int: [ThunderboltDeviceSnapshot]] = [:]
        for device in thunderboltDevices {
            tbBuckets[device.receptaclePort ?? 0, default: []].append(device)
        }

        let tbSessions = tbBuckets.map { port, devices -> CableSession in
            CableSession(
                id: port == 0 ? "tb-0" : "tb-\(port)",
                kind: .thunderbolt,
                receptaclePort: port,
                portLabel: port == 0 ? "雷雳端口（未知）" : "雷雳端口 \(port)",
                thunderboltDevices: devices.sorted { $0.name < $1.name }
            )
        }
        .sorted {
            switch ($0.receptaclePort == 0, $1.receptaclePort == 0) {
            case (true, false): return false
            case (false, true): return true
            default: return $0.receptaclePort! < $1.receptaclePort!
            }
        }

        return portSessions + usbSessions + tbSessions
    }

    // MARK: - 电源归属

    /// 整机电源数据可归属的会话 id（nil = 不可归属，只在整机层展示，不进任何线缆桶）。
    ///
    /// 归属规则（保守优先，宁可不归属也不归错）：
    /// 1. 整机只有一个会话 → 无歧义归属（与 v1 行为一致）；
    /// 2. 多会话时：恰好一个活跃端口在收电（`powerSource.winning` 协商合同存在）且电源已接通
    ///    → 归属该端口的会话。纯 PD 充电线不枚举设备，靠这条才能把充电功率记进线缆评级；
    /// 3. 两个及以上端口同时有协商合同（充电器 + 供电坞站等）或对不上会话 → 不可归属。
    public static func attributablePowerSessionID(sessions: [CableSession],
                                                  ports: [USBCPortSnapshot],
                                                  power: PowerSnapshot?) -> String? {
        if sessions.count == 1 { return sessions[0].id }
        guard let power, power.externalConnected else { return nil }
        let winningPorts = ports.filter { $0.isActive && $0.powerSource?.winning != nil }
        guard winningPorts.count == 1, let port = winningPorts.first else { return nil }
        return sessions.first { $0.physicalPortID == port.portID }?.id
    }
}
