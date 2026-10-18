import Foundation

/*
 Xbox BLE descriptor and input layout adapted from WaveBird.
 MIT License
 Copyright (c) 2026 Joshua Murphy

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 */

enum XboxReports {
    // 仅声明真实 BLE 输入与 PID 输出；不声明未实现的 GIP 通道。
    // Declare only the BLE input and PID output, with no unimplemented GIP stream.
    static let descriptor = Data([
        0x05,0x01,0x09,0x05,0xA1,0x01,0x85,0x01,
        0x09,0x01,0xA1,0x00,0x09,0x30,0x09,0x31,
        0x15,0x00,0x27,0xFF,0xFF,0x00,0x00,0x95,0x02,0x75,0x10,0x81,0x02,0xC0,
        0x09,0x01,0xA1,0x00,0x09,0x32,0x09,0x35,
        0x15,0x00,0x27,0xFF,0xFF,0x00,0x00,0x95,0x02,0x75,0x10,0x81,0x02,0xC0,
        0x05,0x02,0x09,0xC5,0x15,0x00,0x26,0xFF,0x03,0x95,0x01,0x75,0x0A,0x81,0x02,
        0x15,0x00,0x25,0x00,0x75,0x06,0x95,0x01,0x81,0x03,
        0x05,0x02,0x09,0xC4,0x15,0x00,0x26,0xFF,0x03,0x95,0x01,0x75,0x0A,0x81,0x02,
        0x15,0x00,0x25,0x00,0x75,0x06,0x95,0x01,0x81,0x03,
        0x05,0x01,0x09,0x39,0x15,0x01,0x25,0x08,0x35,0x00,0x46,0x3B,0x01,0x66,0x14,0x00,
        0x75,0x04,0x95,0x01,0x81,0x42,0x75,0x04,0x95,0x01,0x15,0x00,0x25,0x00,
        0x35,0x00,0x45,0x00,0x65,0x00,0x81,0x03,
        0x05,0x09,0x19,0x01,0x29,0x0F,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x0F,0x81,0x02,
        0x15,0x00,0x25,0x00,0x75,0x01,0x95,0x01,0x81,0x03,
        0x05,0x0C,0x0A,0xB2,0x00,0x15,0x00,0x25,0x01,0x95,0x01,0x75,0x01,0x81,0x02,
        0x15,0x00,0x25,0x00,0x75,0x07,0x95,0x01,0x81,0x03,
        0x05,0x0F,0x09,0x21,0x85,0x03,0xA1,0x02,0x09,0x97,
        0x15,0x00,0x25,0x01,0x75,0x04,0x95,0x01,0x91,0x02,
        0x15,0x00,0x25,0x00,0x75,0x04,0x95,0x01,0x91,0x03,
        0x09,0x70,0x15,0x00,0x25,0x64,0x75,0x08,0x95,0x04,0x91,0x02,
        0x09,0x50,0x66,0x01,0x10,0x55,0x0E,0x15,0x00,0x26,0xFF,0x00,
        0x75,0x08,0x95,0x01,0x91,0x02,
        0x09,0xA7,0x15,0x00,0x26,0xFF,0x00,0x75,0x08,0x95,0x01,0x91,0x02,
        0x65,0x00,0x55,0x00,0x09,0x7C,0x15,0x00,0x26,0xFF,0x00,
        0x75,0x08,0x95,0x01,0x91,0x02,0xC0,0xC0
    ])

    static func input(buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32) -> Data {
        func pressed(_ bit: Int) -> Bool { buttons & (UInt64(1) << bit) != 0 }
        var bytes = [UInt8](repeating: 0, count: 17)
        bytes[0] = 1
        for (offset, axis) in zip([1, 3, 5, 7], [lx, ly, rx, ry]) {
            let value = UInt16(clamping: Int64(max(-32767, min(32767, axis))) + 32768)
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(value >> 8)
        }
        // 避免部分 SDL GIP 驱动把 BLE 的 LX 误当分片标志；误差至多 128/65536。
        // Avoid SDL GIP drivers treating BLE LX as a fragment flag; error is at most 128/65536.
        bytes[1] &= 0x7F
        if pressed(8) { bytes[9] = 0xFF; bytes[10] = 3 }
        if pressed(9) { bytes[11] = 0xFF; bytes[12] = 3 }
        let dx = (pressed(14) ? 1 : 0) - (pressed(12) ? 1 : 0)
        let dy = (pressed(13) ? 1 : 0) - (pressed(15) ? 1 : 0)
        switch (dx, dy) {
        case (0, 1): bytes[13] = 1
        case (1, 1): bytes[13] = 2
        case (1, 0): bytes[13] = 3
        case (1, -1): bytes[13] = 4
        case (0, -1): bytes[13] = 5
        case (-1, -1): bytes[13] = 6
        case (-1, 0): bytes[13] = 7
        case (-1, 1): bytes[13] = 8
        default: break
        }
        for (source, mask): (Int, UInt8) in [(1,1),(0,2),(3,8),(2,16),(6,64),(7,128)] {
            if pressed(source) { bytes[14] |= mask }
        }
        for (source, mask): (Int, UInt8) in [(11,4),(10,8),(16,16),(4,32),(5,64)] {
            if pressed(source) { bytes[15] |= mask }
        }
        if pressed(17) { bytes[16] |= 1 }
        return Data(bytes)
    }

    struct Rumble: Sendable, Equatable {
        let mask: UInt8
        // 顺序是左扳机、右扳机、左主马达、右主马达；掩码从高位到低位。
        // Order is left trigger, right trigger, left main, right main; mask bits run high to low.
        let magnitudes: [Double]
        let sustain: Double
        let release: Double
        let repeats: Int

        static func decode(reportID: UInt8?, data: Data) throws -> Self {
            let bytes = Array(data)
            let payload: ArraySlice<UInt8>
            // CoreHID 保留客户端提供的内容；仅按确定的长度区分是否包含 ID。
            // CoreHID preserves client bytes; distinguish ID inclusion by exact length.
            if bytes.count == 9, bytes[0] == 3, reportID == nil || reportID == 3 {
                payload = bytes.dropFirst()
            } else if bytes.count == 8, reportID == 3 {
                payload = bytes[...]
            } else {
                throw ReportError.invalidOutput
            }
            let p = Array(payload)
            guard p[0] & 0xF0 == 0, p[1...4].allSatisfy({ $0 <= 100 }) else {
                throw ReportError.invalidOutput
            }
            return Self(mask: p[0], magnitudes: p[1...4].map { Double($0) / 100 },
                        sustain: Double(p[5]) * 0.01, release: Double(p[6]) * 0.01,
                        repeats: Int(p[7]))
        }
    }

    enum ReportError: Error { case invalidOutput }
}
