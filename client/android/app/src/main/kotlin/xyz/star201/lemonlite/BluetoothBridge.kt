package xyz.star201.lemonlite

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max

/**
 * 蓝牙原生桥。
 *
 * 能力范围：
 *   * 适配器状态 / 请求打开 / 已配对列表 / 当前连接列表；
 *   * 扫描：BLE（可带服务 UUID 过滤）+ 经典蓝牙发现，实时 `scanResult` 事件；
 *   * GATT：连接、服务发现、特征值 read/write、notify/indicate 订阅、
 *     RSSI、MTU、连接状态事件；
 *   * 经典蓝牙：`createBond()` 配对 + `bondState` 事件。
 *
 * 为什么经典蓝牙只做「发现 + 配对」而不做 SPP 数据流：
 *   经典蓝牙的串口（SPP）没有统一的 UUID 语义，每个设备的服务/串口参数
 *   都不一样，做成通用 JS API 只会得到一个只能连特定型号的半成品。
 *   BLE 的 GATT 模型才是小程序真正能用的那一层。
 *
 * 跨平台：Dart 侧通过 `BluetoothBackend` 接口调用；本类只实现 Android 通道
 * `lemonlite/bluetooth`。iOS / 桌面实现同一个方法/事件契约即可。
 *
 * 权限：
 *   * Android 12+：BLUETOOTH_SCAN / BLUETOOTH_CONNECT（运行时）
 *   * Android 11 及以下：BLUETOOTH / BLUETOOTH_ADMIN（安装期）+ 扫描需要定位
 * 应用内是否允许某个小程序使用蓝牙，由 Dart 的权限弹窗负责；这里只处理系统层。
 */
class BluetoothBridge(private val activity: Activity) {

    companion object {
        /** 与 Dart 侧 MethodChannelBluetoothBackend 的通道名逐字一致。 */
        const val CHANNEL_NAME = "lemonlite/bluetooth"

        private const val CONNECT_TIMEOUT_MS = 10_000L
        private const val OPERATION_TIMEOUT_MS = 10_000L
        private const val ENABLE_REQUEST = 0x4C42

        /** 标准 CCCD（Client Characteristic Configuration Descriptor）UUID。 */
        private val CCCD_UUID: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val handler = Handler(Looper.getMainLooper())
    private val gatts = ConcurrentHashMap<String, BluetoothGatt>()
    private val currentMtu = ConcurrentHashMap<String, Int>()
    private val subscribed = ConcurrentHashMap<String, Boolean>()

    private var channel: MethodChannel? = null

    // ---- 扫描状态（BLE / 经典蓝牙共用一套结果）----
    private var scanResult: MethodChannel.Result? = null
    private var scanCallback: ScanCallback? = null
    private var scanTimeout: Runnable? = null
    private val scanDevices = LinkedHashMap<String, Map<String, Any?>>()
    private var scanMode = "ble"
    private var scanNamePrefix = ""
    private var scanActive = false
    private var classicDiscovering = false

    // ---- 各类 GATT 异步操作 ----
    private var pendingConnect: PendingConnect? = null
    private var pendingOperation: PendingOperation? = null
    private var pendingMtu: PendingMtu? = null
    private var pendingRssi: PendingRssi? = null
    private var pendingDescriptor: PendingDescriptor? = null

    private var receiverRegistered = false

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                BluetoothDevice.ACTION_FOUND -> {
                    @Suppress("DEPRECATION")
                    val device: BluetoothDevice? =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(
                                BluetoothDevice.EXTRA_DEVICE,
                                BluetoothDevice::class.java,
                            )
                        } else {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                    if (device != null && scanActive) {
                        val map = deviceMap(device, null, "classic")
                        addScanDevice(map)
                        emit("scanResult", map)
                    }
                }

                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                    classicDiscovering = false
                    if (scanActive && scanMode == "classic") {
                        finishScan(null)
                    }
                }

                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    @Suppress("DEPRECATION")
                    val device: BluetoothDevice? =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(
                                BluetoothDevice.EXTRA_DEVICE,
                                BluetoothDevice::class.java,
                            )
                        } else {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                    if (device != null) {
                        val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
                        val previous =
                            intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)
                        emit(
                            "bondState",
                            mapOf(
                                "address" to device.address,
                                "name" to safeName(device),
                                "state" to bondLabel(state),
                                "previousState" to bondLabel(previous),
                            ),
                        )
                    }
                }
            }
        }
    }

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            activity.runOnUiThread { handle(call, result) }
        }
        registerReceivers()
    }

    fun onPause() {
        if (scanActive) {
            finishScan("页面已离开，扫描已停止")
        }
    }

    fun onDestroy() {
        if (scanActive) finishScan("页面已关闭")
        pendingConnect?.let { it.timeout?.let(handler::removeCallbacks) }
        pendingConnect = null
        pendingOperation?.let { it.timeout?.let(handler::removeCallbacks) }
        pendingOperation = null
        pendingMtu?.let { it.timeout?.let(handler::removeCallbacks) }
        pendingMtu = null
        pendingRssi?.let { it.timeout?.let(handler::removeCallbacks) }
        pendingRssi = null
        pendingDescriptor?.let { it.timeout?.let(handler::removeCallbacks) }
        pendingDescriptor = null
        gatts.values.forEach {
            try {
                it.disconnect()
                it.close()
            } catch (_: Throwable) {}
        }
        gatts.clear()
        unregisterReceivers()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ---------------------------------------------------------------- 分发

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(statusMap())
                "listPaired" -> listPaired(result)
                "connections" -> connections(result)
                "scan" -> scan(call, result)
                "requestEnable" -> requestEnable(result)
                "connect" -> connect(call.argument<String>("address") ?: "", result)
                "disconnect" -> disconnect(call.argument<String>("address") ?: "", result)
                "disconnectAll" -> disconnectAll(result)
                "read" -> read(
                    call.argument<String>("address") ?: "",
                    call.argument<String>("service") ?: "",
                    call.argument<String>("characteristic") ?: "",
                    result,
                )
                "write" -> write(
                    call.argument<String>("address") ?: "",
                    call.argument<String>("service") ?: "",
                    call.argument<String>("characteristic") ?: "",
                    call.argument<String>("data") ?: "",
                    call.argument<Boolean>("withResponse") ?: true,
                    result,
                )
                "subscribe" -> subscribe(
                    call.argument<String>("address") ?: "",
                    call.argument<String>("service") ?: "",
                    call.argument<String>("characteristic") ?: "",
                    call.argument<Boolean>("enable") ?: true,
                    result,
                )
                "getRssi" -> getRssi(call.argument<String>("address") ?: "", result)
                "requestMtu" -> requestMtu(
                    call.argument<String>("address") ?: "",
                    call.argument<Number>("mtu")?.toInt() ?: 512,
                    result,
                )
                "pair" -> pair(call.argument<String>("address") ?: "", result)
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
        } catch (e: Exception) {
            result.error("native_error", e.message ?: e.toString(), null)
        }
    }

    // -------------------------------------------------------------- 状态/列表

    private fun statusMap(): Map<String, Any> {
        val a = adapter
        val bleSupported =
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        // Android 12+ 的 isEnabled() 也需要 BLUETOOTH_CONNECT：没授权时不能去问，
        // 否则会抛 SecurityException，让一个「只想知道设备有没有蓝牙」的调用失败。
        val hasConnect = connectPermissionOk()
        val enabled = if (hasConnect) {
            try {
                a?.isEnabled == true
            } catch (_: SecurityException) {
                false
            }
        } else {
            false
        }
        return mapOf(
            "supported" to (a != null),
            "enabled" to enabled,
            "bleSupported" to bleSupported,
            "permissionGranted" to hasConnect,
        )
    }

    private fun listPaired(result: MethodChannel.Result) {
        val a = requireAdapter(result) ?: return
        if (!connectPermissionOk()) {
            result.error("permission_denied", "缺少蓝牙连接权限", null)
            return
        }
        if (!a.isEnabled) {
            result.error("disabled", "蓝牙未打开", null)
            return
        }
        val devices = a.bondedDevices ?: emptySet()
        result.success(
            mapOf(
                "devices" to devices.map { deviceMap(it, null, "paired") },
                "count" to devices.size,
            ),
        )
    }

    private fun connections(result: MethodChannel.Result) {
        val list = gatts.values
            .filter { it.device != null }
            .map { deviceMap(it.device, null, "connected") }
        result.success(mapOf("devices" to list, "count" to list.size))
    }

    private fun requestEnable(result: MethodChannel.Result) {
        val a = requireAdapter(result) ?: return
        if (!connectPermissionOk()) {
            result.error("permission_denied", "缺少蓝牙连接权限", null)
            return
        }
        try {
            // 系统确认框没有同步返回值；Dart 侧用 status() 轮询是否已打开。
            activity.startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                ENABLE_REQUEST,
            )
            result.success(mapOf("requested" to true, "enabled" to a.isEnabled))
        } catch (e: Exception) {
            result.error("native_error", "无法弹出蓝牙开关：${e.message}", null)
        }
    }

    // ------------------------------------------------------------------ 扫描

    private fun scan(call: MethodCall, result: MethodChannel.Result) {
        val a = requireAdapter(result) ?: return
        if (!scanPermissionOk()) {
            result.error("permission_denied", "缺少蓝牙扫描权限", null)
            return
        }
        if (!a.isEnabled) {
            result.error("disabled", "蓝牙未打开", null)
            return
        }
        if (scanActive) {
            result.error("busy", "上一次扫描还没结束", null)
            return
        }

        val mode = (call.argument<String>("mode") ?: "ble").lowercase().let {
            if (it == "classic" || it == "auto") it else "ble"
        }
        val duration = (call.argument<Number>("durationMs")?.toInt() ?: 5000)
            .coerceIn(1000, 20000)
        val serviceUuids = call.argument<List<String>>("serviceUuids") ?: emptyList()
        val prefix = call.argument<String>("namePrefix") ?: ""

        scanMode = mode
        scanNamePrefix = prefix
        scanDevices.clear()
        scanActive = true
        scanResult = result

        var started = false
        if (mode != "classic") {
            started = startBleScan(serviceUuids) || started
        }
        if (mode != "ble") {
            started = startClassicDiscovery() || started
        }

        if (!started) {
            finishScan("蓝牙扫描启动失败")
            return
        }

        val timeout = Runnable { finishScan(null) }
        scanTimeout = timeout
        handler.postDelayed(timeout, duration.toLong())
    }

    private fun startBleScan(serviceUuids: List<String>): Boolean {
        val a = adapter ?: return false
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return false
        }
        val scanner: BluetoothLeScanner = a.bluetoothLeScanner ?: return false

        val filters = serviceUuids.mapNotNull { raw ->
            try {
                ScanFilter.Builder()
                    .setServiceUuid(ParcelUuid(UUID.fromString(raw)))
                    .build()
            } catch (_: Exception) {
                null
            }
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, res: ScanResult?) {
                val item = res ?: return
                activity.runOnUiThread {
                    if (!scanActive) return@runOnUiThread
                    val map = deviceMap(item.device, item, "ble")
                    if (!matchesPrefix(map["name"]?.toString() ?: "")) return@runOnUiThread
                    addScanDevice(map)
                    emit("scanResult", map)
                }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                results?.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
            }

            override fun onScanFailed(errorCode: Int) {
                activity.runOnUiThread {
                    // auto 模式下经典蓝牙可能还在扫：不要因为 BLE 失败就整体失败
                    if (scanActive && scanMode == "ble") {
                        finishScan("蓝牙扫描失败（$errorCode）")
                    }
                }
            }
        }

        scanCallback = callback
        return try {
            scanner.startScan(filters, settings, callback)
            true
        } catch (_: SecurityException) {
            scanCallback = null
            false
        } catch (_: Exception) {
            scanCallback = null
            false
        }
    }

    private fun startClassicDiscovery(): Boolean {
        val a = adapter ?: return false
        return try {
            val ok = a.startDiscovery()
            classicDiscovering = ok
            ok
        } catch (_: SecurityException) {
            false
        }
    }

    private fun addScanDevice(map: Map<String, Any?>) {
        val address = map["address"]?.toString() ?: return
        if (address.isEmpty()) return
        if (!scanDevices.containsKey(address)) {
            scanDevices[address] = map
        }
    }

    private fun matchesPrefix(name: String): Boolean {
        if (scanNamePrefix.isEmpty()) return true
        return name.startsWith(scanNamePrefix, ignoreCase = true)
    }

    /** 结束扫描并回包。error 非空时回 error，否则回当前结果。 */
    private fun finishScan(error: String?) {
        val target = scanResult
        scanResult = null
        scanActive = false

        val callback = scanCallback
        scanCallback = null
        if (callback != null) {
            try {
                adapter?.bluetoothLeScanner?.stopScan(callback)
            } catch (_: Throwable) {}
        }
        if (classicDiscovering) {
            try {
                adapter?.cancelDiscovery()
            } catch (_: Throwable) {}
            classicDiscovering = false
        }
        scanTimeout?.let(handler::removeCallbacks)
        scanTimeout = null

        if (target == null) return
        if (error != null) {
            target.error("scan_failed", error, null)
        } else {
            target.success(
                mapOf(
                    "devices" to scanDevices.values.toList(),
                    "count" to scanDevices.size,
                ),
            )
        }
    }

    // ------------------------------------------------------------- 连接/GATT

    private fun connect(address: String, result: MethodChannel.Result) {
        val a = requireAdapter(result) ?: return
        if (address.isBlank()) {
            result.error("bad_args", "缺少设备地址", null)
            return
        }
        if (!connectPermissionOk()) {
            result.error("permission_denied", "缺少蓝牙连接权限", null)
            return
        }
        if (!a.isEnabled) {
            result.error("disabled", "蓝牙未打开", null)
            return
        }
        gatts[address]?.let { gatt ->
            if (gatt.services.isNotEmpty()) {
                result.success(servicesMap(gatt))
                return
            }
        }
        if (pendingConnect != null) {
            result.error("busy", "上一次连接还在进行中", null)
            return
        }

        val device: BluetoothDevice = try {
            a.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            result.error("bad_args", "设备地址不合法：$address", null)
            return
        }

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(
                gatt: BluetoothGatt,
                status: Int,
                newState: Int,
            ) {
                activity.runOnUiThread {
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        try {
                            gatt.discoverServices()
                        } catch (e: SecurityException) {
                            finishConnect(false, "缺少蓝牙权限：${e.message}", null)
                        }
                    } else {
                        gatts.remove(address)
                        currentMtu.remove(address)
                        try { gatt.close() } catch (_: Throwable) {}
                        emitConnectionState(address, connected = false)
                        finishConnect(
                            false,
                            "连接失败（state=$newState, status=$status）",
                            null,
                        )
                    }
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                activity.runOnUiThread {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        gatts[address] = gatt
                        currentMtu.putIfAbsent(address, 23)
                        emitConnectionState(address, connected = true)
                        finishConnect(true, null, gatt)
                    } else {
                        try { gatt.close() } catch (_: Throwable) {}
                        finishConnect(false, "服务发现失败（$status）", null)
                    }
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                // API < 33 的旧回调；33+ 会走下面带 value 的重载
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    activity.runOnUiThread {
                        if (status == BluetoothGatt.GATT_SUCCESS) {
                            finishOperation(true, null, characteristic.value ?: ByteArray(0))
                        } else {
                            finishOperation(false, "读取失败（$status）", null)
                        }
                    }
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                activity.runOnUiThread {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        finishOperation(true, null, value)
                    } else {
                        finishOperation(false, "读取失败（$status）", null)
                    }
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                activity.runOnUiThread {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        finishOperation(true, null, null)
                    } else {
                        finishOperation(false, "写入失败（$status）", null)
                    }
                }
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    val value = characteristic.value ?: ByteArray(0)
                    activity.runOnUiThread {
                        emitNotification(gatt, characteristic, value)
                    }
                }
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                activity.runOnUiThread {
                    emitNotification(gatt, characteristic, value)
                }
            }

            override fun onDescriptorWrite(
                gatt: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                activity.runOnUiThread {
                    finishDescriptor(
                        status == BluetoothGatt.GATT_SUCCESS,
                        if (status == BluetoothGatt.GATT_SUCCESS) null else "订阅失败（$status）",
                    )
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                activity.runOnUiThread {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        currentMtu[address] = mtu
                        finishMtu(true, mtu, null)
                    } else {
                        finishMtu(false, currentMtu[address] ?: 23, "MTU 协商失败（$status）")
                    }
                }
            }

            override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
                activity.runOnUiThread {
                    finishRssi(
                        status == BluetoothGatt.GATT_SUCCESS,
                        rssi,
                        if (status == BluetoothGatt.GATT_SUCCESS) null else "读取 RSSI 失败（$status）",
                    )
                }
            }
        }

        val gatt = try {
            device.connectGatt(activity, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙连接权限：${e.message}", null)
            return
        } catch (e: Exception) {
            result.error("native_error", "连接失败：${e.message}", null)
            return
        }

        val timeout = Runnable {
            pendingConnect?.let { pending ->
                if (pending.result === result) {
                    pendingConnect = null
                    try {
                        pending.gatt?.disconnect()
                        pending.gatt?.close()
                    } catch (_: Throwable) {}
                    result.error("timeout", "连接超时（${CONNECT_TIMEOUT_MS / 1000} 秒）", null)
                }
            }
        }
        pendingConnect = PendingConnect(address, result, gatt, timeout)
        handler.postDelayed(timeout, CONNECT_TIMEOUT_MS)
    }

    private fun finishConnect(ok: Boolean, error: String?, gatt: BluetoothGatt?) {
        val pending = pendingConnect ?: return
        pendingConnect = null
        pending.timeout?.let(handler::removeCallbacks)
        if (ok && gatt != null) {
            pending.result.success(servicesMap(gatt))
        } else {
            pending.result.error("connect_failed", error ?: "连接失败", null)
        }
    }

    private fun servicesMap(gatt: BluetoothGatt): Map<String, Any?> {
        val services: List<BluetoothGattService> = try {
            gatt.services
        } catch (_: SecurityException) {
            emptyList()
        }
        return mapOf(
            "address" to gatt.device.address,
            "name" to safeName(gatt.device),
            "mtu" to (currentMtu[gatt.device.address] ?: 23),
            "services" to services.map { service ->
                mapOf(
                    "uuid" to service.uuid.toString().uppercase(),
                    "characteristics" to service.characteristics.map { c ->
                        mapOf(
                            "uuid" to c.uuid.toString().uppercase(),
                            "properties" to properties(c.properties),
                        )
                    },
                )
            },
        )
    }

    private fun disconnect(address: String, result: MethodChannel.Result) {
        val gatt = gatts.remove(address)
        currentMtu.remove(address)
        if (gatt == null) {
            result.success(mapOf("address" to address, "disconnected" to false))
            return
        }
        try {
            gatt.disconnect()
            gatt.close()
        } catch (_: Throwable) {}
        emitConnectionState(address, connected = false)
        result.success(mapOf("address" to address, "disconnected" to true))
    }

    private fun disconnectAll(result: MethodChannel.Result) {
        val addresses = gatts.keys.toList()
        for (address in addresses) {
            val gatt = gatts.remove(address) ?: continue
            currentMtu.remove(address)
            try {
                gatt.disconnect()
                gatt.close()
            } catch (_: Throwable) {}
            emitConnectionState(address, connected = false)
        }
        result.success(mapOf("disconnected" to addresses.size))
    }

    // ----------------------------------------------------------------- 读写

    private fun read(
        address: String,
        serviceUuid: String,
        characteristicUuid: String,
        result: MethodChannel.Result,
    ) {
        val gatt = gatts[address]
        if (gatt == null) {
            result.error("not_connected", "设备未连接：$address", null)
            return
        }
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid)
        if (characteristic == null) {
            result.error("not_found", "找不到特征值 $characteristicUuid", null)
            return
        }
        if ((characteristic.properties and BluetoothGattCharacteristic.PROPERTY_READ) == 0) {
            result.error("not_supported", "这个特征值不支持读取", null)
            return
        }
        if (hasPendingOperation()) {
            result.error("busy", "上一次操作还没结束", null)
            return
        }
        val ok = try {
            gatt.readCharacteristic(characteristic)
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
            return
        }
        if (!ok) {
            result.error("read_failed", "读请求发送失败", null)
            return
        }
        awaitOperation(address, result)
    }

    private fun write(
        address: String,
        serviceUuid: String,
        characteristicUuid: String,
        dataBase64: String,
        withResponse: Boolean,
        result: MethodChannel.Result,
    ) {
        val gatt = gatts[address]
        if (gatt == null) {
            result.error("not_connected", "设备未连接：$address", null)
            return
        }
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid)
        if (characteristic == null) {
            result.error("not_found", "找不到特征值 $characteristicUuid", null)
            return
        }
        val required =
            if (withResponse) BluetoothGattCharacteristic.PROPERTY_WRITE
            else BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
        if ((characteristic.properties and required) == 0) {
            result.error("not_supported", "这个特征值不支持该写入方式", null)
            return
        }
        val bytes = try {
            Base64.decode(dataBase64, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            result.error("bad_args", "data 不是合法的 base64", null)
            return
        }
        if (hasPendingOperation()) {
            result.error("busy", "上一次操作还没结束", null)
            return
        }

        val writeType = if (withResponse) {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }

        val sent = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, bytes, writeType) == 0
            } else {
                characteristic.writeType = writeType
                characteristic.value = bytes
                gatt.writeCharacteristic(characteristic)
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
            return
        } catch (e: Exception) {
            result.error("write_failed", "写入失败：${e.message}", null)
            return
        }
        if (!sent) {
            result.error("write_failed", "写请求发送失败", null)
            return
        }

        if (!withResponse) {
            // 无响应写入没有回调；直接按成功返回。
            result.success(mapOf("written" to true, "bytes" to bytes.size))
            return
        }
        awaitOperation(address, result)
    }

    private fun subscribe(
        address: String,
        serviceUuid: String,
        characteristicUuid: String,
        enable: Boolean,
        result: MethodChannel.Result,
    ) {
        val gatt = gatts[address]
        if (gatt == null) {
            result.error("not_connected", "设备未连接：$address", null)
            return
        }
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid)
        if (characteristic == null) {
            result.error("not_found", "找不到特征值 $characteristicUuid", null)
            return
        }
        val supportsNotify =
            (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
        val supportsIndicate =
            (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
        if (!supportsNotify && !supportsIndicate) {
            result.error("not_supported", "这个特征值不支持 notify / indicate", null)
            return
        }
        if (hasPendingOperation()) {
            result.error("busy", "上一次操作还没结束", null)
            return
        }

        val localOk = try {
            gatt.setCharacteristicNotification(characteristic, enable)
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
            return
        }
        if (!localOk) {
            result.error("subscribe_failed", "无法开启本地通知", null)
            return
        }

        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        if (descriptor == null) {
            if (!enable) {
                result.success(mapOf("subscribed" to false))
            } else {
                result.error("not_supported", "这个特征值没有 CCCD，无法订阅", null)
            }
            return
        }

        val value = if (!enable) {
            BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        } else if (supportsIndicate && !supportsNotify) {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        }

        val sent = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, value) == 0
            } else {
                descriptor.value = value
                gatt.writeDescriptor(descriptor)
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
            return
        } catch (e: Exception) {
            result.error("subscribe_failed", "写 CCCD 失败：${e.message}", null)
            return
        }
        if (!sent) {
            result.error("subscribe_failed", "CCCD 写请求发送失败", null)
            return
        }

        val key = "$address|$serviceUuid|$characteristicUuid"
        if (enable) subscribed[key] = true else subscribed.remove(key)
        awaitDescriptor(address, result)
    }

    private fun getRssi(address: String, result: MethodChannel.Result) {
        val gatt = gatts[address]
        if (gatt == null) {
            result.error("not_connected", "设备未连接：$address", null)
            return
        }
        if (pendingRssi != null) {
            result.error("busy", "上一次 RSSI 读取还没结束", null)
            return
        }
        val ok = try {
            gatt.readRemoteRssi()
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
            return
        }
        if (!ok) {
            result.error("rssi_failed", "RSSI 请求发送失败", null)
            return
        }
        val timeout = Runnable {
            pendingRssi?.let {
                pendingRssi = null
                it.timeout?.let { r -> handler.removeCallbacks(r) }
                it.result.error("timeout", "读取 RSSI 超时", null)
            }
        }
        pendingRssi = PendingRssi(result, timeout)
        handler.postDelayed(timeout, OPERATION_TIMEOUT_MS)
    }

    private fun requestMtu(address: String, mtu: Int, result: MethodChannel.Result) {
        val gatt = gatts[address]
        if (gatt == null) {
            result.error("not_connected", "设备未连接：$address", null)
            return
        }
        if (pendingMtu != null) {
            result.error("busy", "上一次 MTU 协商还没结束", null)
            return
        }
        val ok = try {
            gatt.requestMtu(mtu.coerceIn(23, 517))
        } catch (e: SecurityException) {
            result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
            return
        }
        if (!ok) {
            result.error("mtu_failed", "MTU 请求发送失败", null)
            return
        }
        val timeout = Runnable {
            pendingMtu?.let {
                pendingMtu = null
                it.timeout?.let { r -> handler.removeCallbacks(r) }
                it.result.error("timeout", "MTU 协商超时", null)
            }
        }
        pendingMtu = PendingMtu(result, timeout)
        handler.postDelayed(timeout, OPERATION_TIMEOUT_MS)
    }

    private fun pair(address: String, result: MethodChannel.Result) {
        val a = requireAdapter(result) ?: return
        if (!connectPermissionOk()) {
            result.error("permission_denied", "缺少蓝牙连接权限", null)
            return
        }
        val device = try {
            a.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            result.error("bad_args", "设备地址不合法：$address", null)
            return
        }
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            try {
                device.createBond()
            } catch (e: SecurityException) {
                result.error("permission_denied", "缺少蓝牙权限：${e.message}", null)
                return
            }
        } else {
            false
        }
        result.success(
            mapOf(
                "address" to address,
                "requested" to started,
                "bondState" to bondLabel(device.bondState),
            ),
        )
    }

    private fun awaitOperation(address: String, result: MethodChannel.Result) {
        val timeout = Runnable {
            pendingOperation?.let {
                pendingOperation = null
                it.timeout?.let { r -> handler.removeCallbacks(r) }
                it.result.error("timeout", "蓝牙读写超时（${OPERATION_TIMEOUT_MS / 1000} 秒）", null)
            }
        }
        pendingOperation = PendingOperation(address, result, timeout)
        handler.postDelayed(timeout, OPERATION_TIMEOUT_MS)
    }

    private fun finishOperation(ok: Boolean, error: String?, value: ByteArray? = null) {
        val pending = pendingOperation ?: return
        pendingOperation = null
        pending.timeout?.let(handler::removeCallbacks)
        if (!ok) {
            pending.result.error("operation_failed", error ?: "操作失败", null)
            return
        }
        val payload = HashMap<String, Any?>()
        if (value != null) {
            payload["value"] = Base64.encodeToString(value, Base64.NO_WRAP)
        }
        pending.result.success(payload)
    }

    private fun awaitDescriptor(address: String, result: MethodChannel.Result) {
        val timeout = Runnable {
            pendingDescriptor?.let {
                pendingDescriptor = null
                it.timeout?.let { r -> handler.removeCallbacks(r) }
                it.result.error("timeout", "订阅超时", null)
            }
        }
        pendingDescriptor = PendingDescriptor(address, result, timeout)
        handler.postDelayed(timeout, OPERATION_TIMEOUT_MS)
    }

    private fun finishDescriptor(ok: Boolean, error: String?) {
        val pending = pendingDescriptor ?: return
        pendingDescriptor = null
        pending.timeout?.let(handler::removeCallbacks)
        if (ok) {
            pending.result.success(mapOf("subscribed" to true))
        } else {
            pending.result.error("subscribe_failed", error ?: "订阅失败", null)
        }
    }

    private fun finishMtu(ok: Boolean, mtu: Int, error: String?) {
        val pending = pendingMtu ?: return
        pendingMtu = null
        pending.timeout?.let(handler::removeCallbacks)
        if (ok) {
            pending.result.success(mapOf("mtu" to mtu))
        } else {
            pending.result.error("mtu_failed", error ?: "MTU 协商失败", null)
        }
    }

    private fun finishRssi(ok: Boolean, rssi: Int, error: String?) {
        val pending = pendingRssi ?: return
        pendingRssi = null
        pending.timeout?.let(handler::removeCallbacks)
        if (ok) {
            pending.result.success(mapOf("rssi" to rssi))
        } else {
            pending.result.error("rssi_failed", error ?: "读取 RSSI 失败", null)
        }
    }

    private fun emitNotification(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ) {
        val serviceUuid = try {
            gatt.services
                .firstOrNull { service -> service.characteristics.contains(characteristic) }
                ?.uuid
                ?.toString()
                ?.uppercase()
                .orEmpty()
        } catch (_: SecurityException) {
            ""
        }
        emit(
            "notification",
            mapOf(
                "address" to gatt.device.address,
                "service" to serviceUuid,
                "characteristic" to characteristic.uuid.toString().uppercase(),
                "value" to Base64.encodeToString(value, Base64.NO_WRAP),
                "time" to System.currentTimeMillis(),
            ),
        )
    }

    private fun emitConnectionState(address: String, connected: Boolean) {
        val name = gatts[address]?.device?.let { safeName(it) } ?: ""
        emit(
            "connectionState",
            mapOf(
                "address" to address,
                "name" to name,
                "connected" to connected,
                "state" to if (connected) "connected" else "disconnected",
            ),
        )
    }

    private fun emit(type: String, data: Map<String, Any?>) {
        activity.runOnUiThread {
            val ch = channel ?: return@runOnUiThread
            val payload = HashMap<String, Any?>()
            payload["type"] = type
            payload.putAll(data)
            try {
                ch.invokeMethod("event", payload)
            } catch (_: Throwable) {
                // Flutter 引擎已销毁：事件没人收，忽略
            }
        }
    }

    // ------------------------------------------------------------------ 工具

    private fun hasPendingOperation(): Boolean =
        pendingOperation != null ||
            pendingMtu != null ||
            pendingRssi != null ||
            pendingDescriptor != null

    private fun findCharacteristic(
        gatt: BluetoothGatt,
        serviceUuid: String,
        characteristicUuid: String,
    ): BluetoothGattCharacteristic? {
        val service = try {
            gatt.getService(UUID.fromString(serviceUuid))
        } catch (_: IllegalArgumentException) {
            null
        } ?: return null
        return try {
            service.getCharacteristic(UUID.fromString(characteristicUuid))
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun deviceMap(
        device: BluetoothDevice?,
        scan: ScanResult?,
        source: String,
    ): Map<String, Any?> {
        val address = device?.address ?: scan?.device?.address ?: ""
        val name = scan?.scanRecord?.deviceName ?: safeName(device)
        val rssi = scan?.rssi
        val type = device?.type ?: BluetoothDevice.DEVICE_TYPE_UNKNOWN
        return mapOf(
            "address" to address,
            "name" to name,
            "rssi" to (rssi ?: 0),
            "type" to typeLabel(type),
            "source" to source,
            "connectable" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                scan?.isConnectable ?: (type != BluetoothDevice.DEVICE_TYPE_CLASSIC)
            } else {
                type != BluetoothDevice.DEVICE_TYPE_CLASSIC
            },
        )
    }

    private fun safeName(device: BluetoothDevice?): String {
        if (device == null) return ""
        return try {
            device.name ?: ""
        } catch (_: SecurityException) {
            ""
        }
    }

    private fun typeLabel(type: Int): String = when (type) {
        BluetoothDevice.DEVICE_TYPE_CLASSIC -> "classic"
        BluetoothDevice.DEVICE_TYPE_LE -> "le"
        BluetoothDevice.DEVICE_TYPE_DUAL -> "dual"
        else -> "unknown"
    }

    private fun bondLabel(state: Int): String = when (state) {
        BluetoothDevice.BOND_BONDED -> "bonded"
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_NONE -> "none"
        else -> "unknown"
    }

    private fun properties(mask: Int): List<String> {
        val out = ArrayList<String>()
        if (mask and BluetoothGattCharacteristic.PROPERTY_READ != 0) out.add("read")
        if (mask and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) out.add("write")
        if (mask and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            out.add("writeNoResponse")
        }
        if (mask and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) out.add("notify")
        if (mask and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) out.add("indicate")
        if (mask and BluetoothGattCharacteristic.PROPERTY_BROADCAST != 0) out.add("broadcast")
        return out
    }

    private fun requireAdapter(result: MethodChannel.Result): BluetoothAdapter? {
        val a = adapter
        if (a == null) {
            result.error("unsupported", "这台设备没有可用的蓝牙适配器", null)
        }
        return a
    }

    private fun hasPermission(name: String): Boolean =
        activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    private fun scanPermissionOk(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun connectPermissionOk(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            true
        }

    private fun registerReceivers() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                activity.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        } catch (_: Exception) {
            // 注册失败不影响其它能力（只是收不到经典扫描/配对事件）
        }
    }

    private fun unregisterReceivers() {
        if (!receiverRegistered) return
        receiverRegistered = false
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: Exception) {}
    }

    private data class PendingConnect(
        val address: String,
        val result: MethodChannel.Result,
        val gatt: BluetoothGatt?,
        val timeout: Runnable?,
    )

    private data class PendingOperation(
        val address: String,
        val result: MethodChannel.Result,
        val timeout: Runnable?,
    )

    private data class PendingMtu(
        val result: MethodChannel.Result,
        val timeout: Runnable?,
    )

    private data class PendingRssi(
        val result: MethodChannel.Result,
        val timeout: Runnable?,
    )

    private data class PendingDescriptor(
        val address: String,
        val result: MethodChannel.Result,
        val timeout: Runnable?,
    )
}
