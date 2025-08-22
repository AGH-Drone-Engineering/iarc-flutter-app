import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 USB Communication',
      home: UsbDeviceScreen(),
    );
  }
}

class UsbDeviceScreen extends StatefulWidget {
  @override
  _UsbDeviceScreenState createState() => _UsbDeviceScreenState();
}

class _UsbDeviceScreenState extends State<UsbDeviceScreen> {
  UsbPort? _port;
  UsbDevice? _device;
  List<UsbDevice> _devices = [];
  String _receivedData = '';
  String _connectionStatus = 'No device connected';

  @override
  void initState() {
    super.initState();
    _getDevices();
  }

  // Get a list of all connected USB devices
  Future<void> _getDevices() async {
    _devices = await UsbSerial.listDevices();
    setState(() {});
  }

  // Connect to the selected USB device
  Future<void> _connectUsbDevice(UsbDevice device) async {
    _device = device;
    try {
      _port = await device.create();
      await _port?.open();
      await _port?.setDTR(true); // Set Data Terminal Ready signal
      await _port?.setRTS(true); // Set Request to Send signal
      setState(() {
        _connectionStatus = 'Device connected: ${_device?.deviceName}';
      });
    } catch (e) {
      setState(() {
        _connectionStatus = 'Failed to connect: $e';
      });
    }
  }

  // Send data to the ESP32 via USB
  Future<void> _sendData(String data) async {
    if (_port != null) {
      await _port?.write(Uint8List.fromList(data.codeUnits));
    }
  }

  // Read data from the ESP32 via USB
  Future<void> _receiveData() async {
    if (_port != null) {
      _port!.inputStream?.listen((Uint8List data) {
        String receivedData = String.fromCharCodes(data);
        setState(() {
          _receivedData = receivedData;
        });
      });
    }
  }

  // Disconnect from the device
  void _disconnectUsbDevice() {
    _port?.close();
    setState(() {
      _device = null;
      _port = null;
      _receivedData = '';
      _connectionStatus = 'No device connected';
    });
  }

  @override
  void dispose() {
    _port?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('ESP32 USB Communication')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // Display connected USB devices
            DropdownButton<UsbDevice>(
              hint: Text('Select a USB Device'),
              items: _devices.map((device) {
                return DropdownMenuItem<UsbDevice>(
                  value: device,
                  child: Text(device.deviceName),
                );
              }).toList(),
              onChanged: (device) {
                if (device != null) {
                  _connectUsbDevice(device);
                }
              },
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _sendData("Hello ESP32"),
              child: Text('Send Data to ESP32'),
            ),
            ElevatedButton(
              onPressed: _receiveData,
              child: Text('Receive Data from ESP32'),
            ),
            SizedBox(height: 20),
            Text('Received Data:'),
            Text(_receivedData),
            SizedBox(height: 20),
            Text(_connectionStatus),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _disconnectUsbDevice,
              child: Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
