import PolymerBase

@MainActor let baseChecks: [Check] = [
    Check("base.geometry") { c in
        let r = Rect(x: 10, y: 20, width: 100, height: 50)
        c.expectEqual(r.intersection(Rect(x: 50, y: 0, width: 100, height: 40)), Rect(x: 50, y: 20, width: 60, height: 20))
        c.expectEqual(r.union(.zero), r)
        c.expect(r.contains(Point(x: 10, y: 20)) && !r.contains(Point(x: 110, y: 20)), "contains is half-open")
        let t = AffineTransform.scale(x: 2, y: 3).concatenating(.translation(x: 1, y: 1))
        c.expectEqual(t.apply(Point(x: 1, y: 1)), Point(x: 3, y: 4))
    },
    Check("base.math") { c in
        for (x, expected) in [(2.0, 0.6931471805599453), (10.0, 2.302585092994046), (0.001, -6.907755278982137)] {
            c.expectClose(Math.log(x), expected, tolerance: 1e-15, "log(\(x))")
        }
        for (x, expected) in [(1.0, 2.718281828459045), (-3.5, 0.0301973834223185), (20.0, 485165195.4097903)] {
            c.expectClose(Math.exp(x) / expected, 1, tolerance: 4e-16, "exp(\(x))")
        }
        c.expectClose(pow(base: 2, 10), 1024, tolerance: 1e-12, "2^10")
        // Reference values (correctly rounded).
        for (x, s, co) in [(1.0, 0.8414709848078965, 0.5403023058681398), (-2.5, -0.5984721441039565, -0.8011436155469337),
                           (0.1, 0.09983341664682815, 0.9950041652780258), (100.0, -0.5063656411097588, 0.8623188722876839),
                           (3.141592653589793, 1.2246467991473532e-16, -1.0)] {
            c.expectClose(Math.sin(x), s, tolerance: 2e-16 * max(1, abs(x)), "sin(\(x))")
            c.expectClose(Math.cos(x), co, tolerance: 2e-16 * max(1, abs(x)), "cos(\(x))")
        }
    },
    Check("base.color") { c in
        for v in 0..<256 {
            let lin = SRGB.decode8[v]
            c.expectEqual(SRGB.encode8(lin), UInt8(v), "sRGB round trip of \(v)")
        }
        c.expectEqual(Color(hex: 0x1A2B3C).description, "#1A2B3C")
        c.expectClose(Double(Color(white: 0.5).linear.r), 0.21404114048223255, tolerance: 1e-6, "linear 0.5")
    },
    Check("base.stableID") { c in
        // Fixed values: these must never change, on any OS.
        c.expectEqual(StableID("albums").description, StableID("albums").description)
        c.expect(StableID("a").appending("bc") != StableID("ab").appending("c"), "path steps are separated")
        c.note("StableID(\"albums\") = \(StableID("albums"))")
        c.expectEqual(StableID("albums").description, "63f024519d5b97d5", "fixed value")
    },
    Check("base.json") { c in
        let text = #"{"b": [1, 2.5, -0.001, 1e300], "a": "x\"\n\u00e9\ud83d\ude00", "c": null, "d": true}"#
        let v = try JSON.parse(text)
        c.expectEqual(v["a"]?.string, "x\"\né😀")
        c.expectEqual(v["b"]?[2]?.double, -0.001)
        c.expectEqual(v.serialized, #"{"a":"x\"\né😀","b":[1,2.5,-0.001,1e+300],"c":null,"d":true}"#)
        c.expectEqual(try JSON.parse(v.pretty), v, "pretty output parses back")
        do {
            _ = try JSON.parse("{\n  \"a\": 1,\n  \"b\" 2\n}")
            c.fail("missing ':' was accepted")
        } catch let error as JSON.ParseError {
            c.expectEqual(error.line, 3, "error line")
            c.expect(error.message.contains("':'"), "error says what is missing: \(error.message)")
        }
        for bad in ["[1,]", "01", "\"\\x\"", "{\"a\":1,\"a\":2}", "[1] 2", "nul"] {
            c.expect((try? JSON.parse(bad)) == nil, "rejects \(bad)")
        }
    },
    Check("base.zlib") { c in
        var data: [UInt8] = []
        var seed: UInt32 = 12345
        for k in 0..<200_000 {
            seed = seed &* 1103515245 &+ 12345
            data.append(k % 3000 < 1500 ? UInt8(k % 7) : UInt8(truncatingIfNeeded: seed >> 16))
        }
        let packed = Zlib.compress(data)
        c.expectEqual(try Zlib.decompress(packed), data, "round trip")
        c.note("zlib: \(data.count) -> \(packed.count) bytes")
        c.expectEqual(try Zlib.decompress(Zlib.compress([])), [], "empty")
        c.expectEqual(Checksum.crc32(Array("123456789".utf8)), 0xCBF43926, "CRC-32 check value")
        c.expectEqual(Checksum.adler32(Array("Wikipedia".utf8)), 0x11E60398, "Adler-32 check value")
    },
]
