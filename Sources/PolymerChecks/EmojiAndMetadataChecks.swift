// Headless deterministic checks for OpenType CPAL/COLR v0 color glyphs
// and pure-Swift multi-container audio metadata parsing.
import PolymerBase
import PolymerText
import PolymerRender
import PolymerAudio

@MainActor public let emojiAndMetadataChecks: [Check] = [
    Check("text.color-emoji") { c in
        // 1. Build synthetic CPAL (2 palettes x 4 entries) + COLR v0 (3 base glyphs, unsorted input to verify sort + binary search).
        let red = Color(hex: 0xE63946)
        let gold = Color(hex: 0xFFB703)
        let blue = Color(hex: 0x219EBC)
        let greenHalf = Color(hex: 0x2A9D8F, opacity: 0.5)

        let teal = Color(hex: 0x00B4D8)
        let amber = Color(hex: 0xF77F00)
        let slate = Color(hex: 0x4A5759)
        let crimson = Color(hex: 0xD62828)

        let palettes: [[Color]] = [
            [red, gold, blue, greenHalf],
            [teal, amber, slate, crimson],
        ]

        // Deliberately supply base glyphs out of order so builder sorting & binary search are verified.
        let glyphSpecs: [(baseGlyphID: UInt16, layers: [ColorGlyphLayer])] = [
            (300, [
                ColorGlyphLayer(glyphID: 301, paletteEntryIndex: 2),
                ColorGlyphLayer(glyphID: 302, paletteEntryIndex: CPALTable.foregroundEntryIndex),
            ]),
            (100, [
                ColorGlyphLayer(glyphID: 101, paletteEntryIndex: 0),
                ColorGlyphLayer(glyphID: 102, paletteEntryIndex: 1),
                ColorGlyphLayer(glyphID: 103, paletteEntryIndex: CPALTable.foregroundEntryIndex),
            ]),
            (200, [
                ColorGlyphLayer(glyphID: 201, paletteEntryIndex: 0),
                ColorGlyphLayer(glyphID: 202, paletteEntryIndex: 1),
                ColorGlyphLayer(glyphID: 203, paletteEntryIndex: 2),
                ColorGlyphLayer(glyphID: 204, paletteEntryIndex: 3),
            ]),
        ]

        let tables = ColorGlyphTable.buildSyntheticTables(palettes: palettes, glyphs: glyphSpecs)
        guard let colorTable = ColorGlyphTable(colrData: tables.colr, cpalData: tables.cpal) else {
            c.fail("failed to parse synthetic COLR/CPAL tables")
            return
        }

        // 2. Verify CPAL header, BGRA -> sRGB decoding, and 0xFFFF foreground handling.
        let cpal = colorTable.cpal
        c.expectEqual(cpal.version, 0, "CPAL version 0")
        c.expectEqual(cpal.numPalettes, 2, "CPAL palette count")
        c.expectEqual(cpal.numPaletteEntries, 4, "CPAL entries per palette")
        c.expectEqual(cpal.numColorRecords, 8, "CPAL total color records")

        if let p0e0 = cpal.color(paletteIndex: 0, entryIndex: 0) {
            c.expectClose(p0e0.red, red.red, tolerance: 1.0 / 255.0, "palette 0 entry 0 red")
            c.expectClose(p0e0.green, red.green, tolerance: 1.0 / 255.0, "palette 0 entry 0 green")
            c.expectClose(p0e0.blue, red.blue, tolerance: 1.0 / 255.0, "palette 0 entry 0 blue")
            c.expectClose(p0e0.opacity, 1.0, tolerance: 1.0 / 255.0, "palette 0 entry 0 alpha")
        } else {
            c.fail("palette 0 entry 0 missing")
        }

        if let p0e3 = cpal.color(paletteIndex: 0, entryIndex: 3) {
            c.expectClose(p0e3.opacity, 0.5, tolerance: 1.0 / 255.0, "BGRA semi-transparent alpha preserved")
        } else {
            c.fail("palette 0 entry 3 missing")
        }

        if let p1e1 = cpal.color(paletteIndex: 1, entryIndex: 1) {
            c.expectClose(p1e1.red, amber.red, tolerance: 1.0 / 255.0, "palette 1 entry 1 red")
            c.expectClose(p1e1.green, amber.green, tolerance: 1.0 / 255.0, "palette 1 entry 1 green")
            c.expectClose(p1e1.blue, amber.blue, tolerance: 1.0 / 255.0, "palette 1 entry 1 blue")
        } else {
            c.fail("palette 1 entry 1 missing")
        }

        c.expectEqual(cpal.color(paletteIndex: 0, entryIndex: 0xFFFF), nil, "0xFFFF returns nil from color(paletteIndex:entryIndex:)")
        c.expectEqual(cpal.color(paletteIndex: 2, entryIndex: 0), nil, "out-of-range palette returns nil")
        c.expectEqual(cpal.color(paletteIndex: 0, entryIndex: 4), nil, "out-of-range entry returns nil")

        let customFG = Color(hex: 0x00FF88)
        c.expectEqual(
            cpal.resolveColor(paletteIndex: 0, entryIndex: CPALTable.foregroundEntryIndex, foreground: customFG),
            customFG,
            "0xFFFF resolves to foreground color"
        )

        // 3. Verify COLR v0 header and binary search lookup.
        let colr = colorTable.colr
        c.expectEqual(colr.version, 0, "COLR version 0")
        c.expectEqual(colr.numBaseGlyphRecords, 3, "COLR base glyph count")
        c.expectEqual(colr.numLayerRecords, 9, "COLR total layer count")
        c.expectEqual(colr.baseGlyphRecords.map(\.glyphID), [100, 200, 300], "base glyph records sorted for binary search")

        c.expectEqual(colr.layers(for: 50), nil, "missing glyph below range returns nil")
        c.expectEqual(colr.layers(for: 150), nil, "missing glyph inside range returns nil")
        c.expectEqual(colr.layers(for: 999), nil, "missing glyph above range returns nil")

        let l100 = colr.layers(for: 100)
        c.expectEqual(l100?.count, 3, "glyph 100 has 3 layers")
        c.expectEqual(l100?.last?.usesForegroundColor, true, "glyph 100 top layer uses foreground color")
        c.expectEqual(colr.layers(for: 200)?.count, 4, "glyph 200 has 4 layers")
        c.expectEqual(colr.layers(for: 300)?.count, 2, "glyph 300 has 2 layers")

        // 4. Verify palette switching & foreground substitution on resolvedLayers().
        guard let resolvedP0 = colorTable.resolvedLayers(for: 100, palette: 0, foreground: customFG),
              let resolvedP1 = colorTable.resolvedLayers(for: 100, palette: 1, foreground: .white) else {
            c.fail("resolvedLayers failed for base glyph 100")
            return
        }
        c.expectEqual(resolvedP0.count, 3, "resolved palette 0 layer count")
        c.expectEqual(resolvedP0[2].color, customFG, "palette 0 foreground layer uses customFG")
        c.expectEqual(resolvedP1[2].color, .white, "palette 1 foreground layer uses white")
        c.expect(resolvedP0[0].color != resolvedP1[0].color, "palette switching changes base layer color")

        // 5. Render layered outlines onto PolymerRender.Canvas and verify multi-color output pixels.
        let outlines: [UInt16: Path] = [
            101: Path(rect: Rect(x: 4, y: 4, width: 56, height: 56)),     // outer base
            102: Path(rect: Rect(x: 16, y: 16, width: 32, height: 32)),   // inner accent
            103: Path(rect: Rect(x: 26, y: 26, width: 12, height: 12)),   // foreground center
        ]

        var canvasP0 = Canvas(width: 64, height: 64, scale: 1, background: .black)
        for layer in resolvedP0 {
            if let path = outlines[layer.glyphID] {
                canvasP0.fill(path, layer.color)
            }
        }
        let bmpP0 = canvasP0.bitmap

        // Sample distinct regions: background (1,1), layer 101 red (8,8), layer 102 gold (20,20), layer 103 customFG (32,32).
        let pxBg = bmpP0[1, 1]
        let pxL0 = bmpP0[8, 8]
        let pxL1 = bmpP0[20, 20]
        let pxL2 = bmpP0[32, 32]

        c.expectEqual(pxBg.r, 0, "background R is 0")
        c.expectEqual(pxBg.g, 0, "background G is 0")
        c.expectEqual(pxBg.b, 0, "background B is 0")

        c.expectEqual(pxL0.r, 0xE6, "layer 0 (red) R matches")
        c.expectEqual(pxL0.g, 0x39, "layer 0 (red) G matches")
        c.expectEqual(pxL0.b, 0x46, "layer 0 (red) B matches")

        c.expectEqual(pxL1.r, 0xFF, "layer 1 (gold) R matches")
        c.expectEqual(pxL1.g, 0xB7, "layer 1 (gold) G matches")
        c.expectEqual(pxL1.b, 0x03, "layer 1 (gold) B matches")

        c.expectEqual(pxL2.r, 0x00, "layer 2 (foreground 0x00FF88) R matches")
        c.expectEqual(pxL2.g, 0xFF, "layer 2 (foreground 0x00FF88) G matches")
        c.expectEqual(pxL2.b, 0x88, "layer 2 (foreground 0x00FF88) B matches")

        // Render with palette 1 + white foreground and confirm distinct multi-color pixels.
        var canvasP1 = Canvas(width: 64, height: 64, scale: 1, background: .black)
        for layer in resolvedP1 {
            if let path = outlines[layer.glyphID] {
                canvasP1.fill(path, layer.color)
            }
        }
        let bmpP1 = canvasP1.bitmap
        c.expectEqual(bmpP1[8, 8].r, 0x00, "palette 1 layer 0 (teal) R matches")
        c.expectEqual(bmpP1[8, 8].g, 0xB4, "palette 1 layer 0 (teal) G matches")
        c.expectEqual(bmpP1[8, 8].b, 0xD8, "palette 1 layer 0 (teal) B matches")
        c.expectEqual(bmpP1[32, 32].r, 0xFF, "palette 1 foreground (white) R matches")
        c.expectEqual(bmpP1[32, 32].g, 0xFF, "palette 1 foreground (white) G matches")
        c.expectEqual(bmpP1[32, 32].b, 0xFF, "palette 1 foreground (white) B matches")

        c.note("COLR v0 glyphs=\(colr.numBaseGlyphRecords), layers=\(colr.numLayerRecords), CPAL palettes=\(cpal.numPalettes)")
    },

    Check("audio.metadata") { c in
        // Encode a real tiny 2x2 PNG artwork payload for embedded artwork verification.
        let artBitmap = Bitmap(width: 2, height: 2, fill: (0x3A, 0x82, 0xF6, 0xFF))
        let pngArtwork = PNG.encode(artBitmap)

        // 1. FLAC (STREAMINFO + VORBIS_COMMENT + ReplayGain + embedded PNG PICTURE).
        let flacBytes = AudioMetadataParser.makeFLACMetadata(
            sampleRate: 96_000,
            channels: 2,
            bitDepth: 24,
            totalSamples: 288_000,
            comments: [
                ("TITLE", "Midnight Grid"),
                ("ARTIST", "Polymer Ensemble"),
                ("ALBUM", "Reference Signals"),
                ("ALBUMARTIST", "Polymer Audio"),
                ("TRACKNUMBER", "3/12"),
                ("DISCNUMBER", "1/2"),
                ("DATE", "2026-05-01"),
                ("GENRE", "Electronic"),
                ("COMMENT", "Mastered in 64-bit float"),
                ("REPLAYGAIN_TRACK_GAIN", "-6.50 dB"),
                ("REPLAYGAIN_ALBUM_GAIN", "-7.25 dB"),
                ("REPLAYGAIN_TRACK_PEAK", "0.987654"),
                ("REPLAYGAIN_ALBUM_PEAK", "0.991234"),
                ("ENCODER", "PolymerFLAC"),
            ],
            artwork: pngArtwork,
            artworkMIME: "image/png"
        )
        let flacMeta = AudioMetadataParser.parse(flacBytes)
        c.expectEqual(flacMeta.format, .flac, "FLAC format detected")
        c.expectEqual(flacMeta.sampleRate, 96_000, "FLAC sampleRate")
        c.expectEqual(flacMeta.bitDepth, 24, "FLAC bitDepth")
        c.expectEqual(flacMeta.channels, 2, "FLAC channels")
        c.expectClose(flacMeta.durationSeconds ?? -1, 3.0, tolerance: 1e-6, "FLAC durationSeconds")
        c.expectEqual(flacMeta.title, "Midnight Grid", "FLAC title")
        c.expectEqual(flacMeta.artist, "Polymer Ensemble", "FLAC artist")
        c.expectEqual(flacMeta.album, "Reference Signals", "FLAC album")
        c.expectEqual(flacMeta.albumArtist, "Polymer Audio", "FLAC albumArtist")
        c.expectEqual(flacMeta.trackNumber, 3, "FLAC trackNumber")
        c.expectEqual(flacMeta.trackTotal, 12, "FLAC trackTotal")
        c.expectEqual(flacMeta.discNumber, 1, "FLAC discNumber")
        c.expectEqual(flacMeta.discTotal, 2, "FLAC discTotal")
        c.expectEqual(flacMeta.year, 2026, "FLAC year")
        c.expectEqual(flacMeta.genre, "Electronic", "FLAC genre")
        c.expectEqual(flacMeta.comment, "Mastered in 64-bit float", "FLAC comment")
        c.expectClose(flacMeta.replayGainTrackDB ?? 0, -6.5, tolerance: 1e-6, "FLAC RG track dB")
        c.expectClose(flacMeta.replayGainAlbumDB ?? 0, -7.25, tolerance: 1e-6, "FLAC RG album dB")
        c.expectClose(flacMeta.replayGainTrackPeak ?? 0, 0.987654, tolerance: 1e-6, "FLAC RG track peak")
        c.expectClose(flacMeta.replayGainAlbumPeak ?? 0, 0.991234, tolerance: 1e-6, "FLAC RG album peak")
        c.expectEqual(flacMeta.extraTags["ENCODER"], "PolymerFLAC", "FLAC custom extra tag")
        c.expectEqual(flacMeta.artworkMIME, "image/png", "FLAC artwork MIME")
        c.expectEqual(flacMeta.artwork, pngArtwork, "FLAC artwork bytes exact match")

        // 2. ID3v2.3 (UTF-16LE with BOM, ISO-8859-1, COMM, TXXX ReplayGain, APIC + trailing MP3 frames).
        let rawMP3 = MP3TestFrameBuilder.buildStream(MP3TestFrameBuilder.Spec(
            sampleRate: 44_100,
            bitrateKbps: 128,
            channelMode: .stereo,
            frameCount: 4,
            includeID3v2: false,
            includeID3v1: false,
            useBitReservoir: false
        ))
        let id3v23Bytes = AudioMetadataParser.makeID3v23(
            frames: [
                ("TIT2", AudioMetadataParser.makeID3TextBody("Caf\u{00E9} \u{2014} Nocturne", encoding: 1)),
                ("TPE1", AudioMetadataParser.makeID3TextBody("Ren\u{00E9} Glass", encoding: 0)),
                ("TALB", AudioMetadataParser.makeID3TextBody("Analog Tape", encoding: 1)),
                ("TPE2", AudioMetadataParser.makeID3TextBody("Studio Collection", encoding: 0)),
                ("TRCK", AudioMetadataParser.makeID3TextBody("4/10", encoding: 0)),
                ("TPOS", AudioMetadataParser.makeID3TextBody("2/2", encoding: 0)),
                ("TYER", AudioMetadataParser.makeID3TextBody("2025", encoding: 0)),
                ("TCON", AudioMetadataParser.makeID3TextBody("(17)Ambient", encoding: 0)),
                ("COMM", AudioMetadataParser.makeID3COMMBody(language: "eng", shortDescription: "Notes", text: "Recorded live", encoding: 1)),
                ("TXXX", AudioMetadataParser.makeID3TXXXBody(description: "REPLAYGAIN_TRACK_GAIN", value: "-4.20 dB", encoding: 1)),
                ("TXXX", AudioMetadataParser.makeID3TXXXBody(description: "REPLAYGAIN_TRACK_PEAK", value: "0.912", encoding: 0)),
                ("TXXX", AudioMetadataParser.makeID3TXXXBody(description: "MOOD", value: "Calm", encoding: 0)),
                ("APIC", AudioMetadataParser.makeID3APICBody(mime: "image/png", pictureType: 3, description: "Cover", imageData: pngArtwork)),
            ],
            trailingAudio: rawMP3
        )
        let id3v23Meta = AudioMetadataParser.parse(id3v23Bytes)
        c.expectEqual(id3v23Meta.format, .mp3, "ID3v2.3 format is mp3")
        c.expectEqual(id3v23Meta.title, "Caf\u{00E9} \u{2014} Nocturne", "ID3v2.3 UTF-16LE title")
        c.expectEqual(id3v23Meta.artist, "Ren\u{00E9} Glass", "ID3v2.3 ISO-8859-1 artist")
        c.expectEqual(id3v23Meta.album, "Analog Tape", "ID3v2.3 UTF-16LE album")
        c.expectEqual(id3v23Meta.albumArtist, "Studio Collection", "ID3v2.3 albumArtist")
        c.expectEqual(id3v23Meta.trackNumber, 4, "ID3v2.3 trackNumber")
        c.expectEqual(id3v23Meta.trackTotal, 10, "ID3v2.3 trackTotal")
        c.expectEqual(id3v23Meta.discNumber, 2, "ID3v2.3 discNumber")
        c.expectEqual(id3v23Meta.discTotal, 2, "ID3v2.3 discTotal")
        c.expectEqual(id3v23Meta.year, 2025, "ID3v2.3 year")
        c.expectEqual(id3v23Meta.genre, "Ambient", "ID3v2.3 genre normalized")
        c.expectEqual(id3v23Meta.comment, "Recorded live", "ID3v2.3 COMM UTF-16LE comment")
        c.expectClose(id3v23Meta.replayGainTrackDB ?? 0, -4.2, tolerance: 1e-6, "ID3v2.3 TXXX RG track dB")
        c.expectClose(id3v23Meta.replayGainTrackPeak ?? 0, 0.912, tolerance: 1e-6, "ID3v2.3 TXXX RG track peak")
        c.expectEqual(id3v23Meta.extraTags["MOOD"], "Calm", "ID3v2.3 custom TXXX tag")
        c.expectEqual(id3v23Meta.artworkMIME, "image/png", "ID3v2.3 APIC MIME")
        c.expectEqual(id3v23Meta.artwork, pngArtwork, "ID3v2.3 APIC artwork bytes")
        c.expectEqual(id3v23Meta.sampleRate, 44_100, "ID3v2.3 trailing MP3 frame sampleRate")
        c.expectEqual(id3v23Meta.channels, 2, "ID3v2.3 trailing MP3 frame channels")
        c.expectClose(id3v23Meta.durationSeconds ?? 0, Double(4 * 1152) / 44_100.0, tolerance: 1e-5, "MP3 duration from frame walk")

        // 3. ID3v2.4 (UTF-8 + synchsafe frame sizes + TDRC + album ReplayGain).
        let id3v24Bytes = AudioMetadataParser.makeID3v24(frames: [
            ("TIT2", AudioMetadataParser.makeID3TextBody("\u{97F3}\u{697D} Signal", encoding: 3)),
            ("TPE1", AudioMetadataParser.makeID3TextBody("Kuroda", encoding: 3)),
            ("TDRC", AudioMetadataParser.makeID3TextBody("2026-11-24", encoding: 3)),
            ("TXXX", AudioMetadataParser.makeID3TXXXBody(description: "replaygain_album_gain", value: "+1.25 dB", encoding: 3)),
            ("TXXX", AudioMetadataParser.makeID3TXXXBody(description: "replaygain_album_peak", value: "0.845", encoding: 3)),
        ])
        let id3v24Meta = AudioMetadataParser.parse(id3v24Bytes)
        c.expectEqual(id3v24Meta.format, .mp3, "ID3v2.4 format")
        c.expectEqual(id3v24Meta.title, "\u{97F3}\u{697D} Signal", "ID3v2.4 UTF-8 title")
        c.expectEqual(id3v24Meta.artist, "Kuroda", "ID3v2.4 UTF-8 artist")
        c.expectEqual(id3v24Meta.year, 2026, "ID3v2.4 TDRC year")
        c.expectClose(id3v24Meta.replayGainAlbumDB ?? 0, 1.25, tolerance: 1e-6, "ID3v2.4 RG album gain")
        c.expectClose(id3v24Meta.replayGainAlbumPeak ?? 0, 0.845, tolerance: 1e-6, "ID3v2.4 RG album peak")

        // 4. MP4 / M4A (ALAC stsd/cookie + mdhd + ilst atoms + trkn/disk + covr).
        let m4aBytes = AudioMetadataParser.makeM4AMetadata(
            sampleRate: 48_000,
            channels: 2,
            bitDepth: 24,
            totalSamples: 96_000,
            isALAC: true,
            title: "Glass Harmonics",
            artist: "M. Takahashi",
            album: "Monochrome",
            albumArtist: "Polymer Records",
            trackNumber: 7,
            trackTotal: 14,
            discNumber: 1,
            discTotal: 3,
            year: "2024-09-10",
            genre: "Jazz",
            comment: "ALAC 24/48",
            artwork: pngArtwork,
            artworkIsPNG: true
        )
        let m4aMeta = AudioMetadataParser.parse(m4aBytes)
        c.expectEqual(m4aMeta.format, .alac, "M4A ALAC format detected")
        c.expectEqual(m4aMeta.sampleRate, 48_000, "M4A sampleRate")
        c.expectEqual(m4aMeta.bitDepth, 24, "M4A bitDepth")
        c.expectEqual(m4aMeta.channels, 2, "M4A channels")
        c.expectClose(m4aMeta.durationSeconds ?? 0, 2.0, tolerance: 1e-6, "M4A mdhd duration")
        c.expectEqual(m4aMeta.title, "Glass Harmonics", "M4A ©nam title")
        c.expectEqual(m4aMeta.artist, "M. Takahashi", "M4A ©ART artist")
        c.expectEqual(m4aMeta.album, "Monochrome", "M4A ©alb album")
        c.expectEqual(m4aMeta.albumArtist, "Polymer Records", "M4A aART albumArtist")
        c.expectEqual(m4aMeta.trackNumber, 7, "M4A trkn number")
        c.expectEqual(m4aMeta.trackTotal, 14, "M4A trkn total")
        c.expectEqual(m4aMeta.discNumber, 1, "M4A disk number")
        c.expectEqual(m4aMeta.discTotal, 3, "M4A disk total")
        c.expectEqual(m4aMeta.year, 2024, "M4A ©day year")
        c.expectEqual(m4aMeta.genre, "Jazz", "M4A ©gen genre")
        c.expectEqual(m4aMeta.comment, "ALAC 24/48", "M4A ©cmt comment")
        c.expectEqual(m4aMeta.artworkMIME, "image/png", "M4A covr PNG MIME")
        c.expectEqual(m4aMeta.artwork, pngArtwork, "M4A covr artwork bytes")

        // 5. WAV (fmt + LIST/INFO + duration).
        let wavBytes = AudioMetadataParser.makeWAVMetadata(
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16,
            frameCount: 88_200,
            info: [
                ("INAM", "Linear PCM Study"),
                ("IART", "Studio Lab"),
                ("IPRD", "Test Masters"),
                ("ICRD", "2023"),
                ("IGNR", "Acoustic"),
                ("ITRK", "2/8"),
                ("ICMT", "Direct capture"),
            ]
        )
        let wavMeta = AudioMetadataParser.parse(wavBytes)
        c.expectEqual(wavMeta.format, .wav, "WAV format")
        c.expectEqual(wavMeta.sampleRate, 44_100, "WAV sampleRate")
        c.expectEqual(wavMeta.bitDepth, 16, "WAV bitDepth")
        c.expectEqual(wavMeta.channels, 2, "WAV channels")
        c.expectClose(wavMeta.durationSeconds ?? 0, 2.0, tolerance: 1e-6, "WAV duration")
        c.expectEqual(wavMeta.title, "Linear PCM Study", "WAV INAM title")
        c.expectEqual(wavMeta.artist, "Studio Lab", "WAV IART artist")
        c.expectEqual(wavMeta.album, "Test Masters", "WAV IPRD album")
        c.expectEqual(wavMeta.year, 2023, "WAV ICRD year")
        c.expectEqual(wavMeta.genre, "Acoustic", "WAV IGNR genre")
        c.expectEqual(wavMeta.trackNumber, 2, "WAV ITRK trackNumber")
        c.expectEqual(wavMeta.trackTotal, 8, "WAV ITRK trackTotal")
        c.expectEqual(wavMeta.comment, "Direct capture", "WAV ICMT comment")

        // 6. AIFF (COMM 80-bit extended sample rate + NAME/AUTH/ANNO).
        let aiffBytes = AudioMetadataParser.makeAIFFMetadata(
            sampleRate: 96_000,
            channels: 2,
            bitDepth: 24,
            frameCount: 48_000,
            name: "Tape Loop",
            author: "Archivist",
            annotation: "24-bit 96 kHz AIFF"
        )
        let aiffMeta = AudioMetadataParser.parse(aiffBytes)
        c.expectEqual(aiffMeta.format, .aiff, "AIFF format")
        c.expectEqual(aiffMeta.sampleRate, 96_000, "AIFF sampleRate")
        c.expectEqual(aiffMeta.bitDepth, 24, "AIFF bitDepth")
        c.expectEqual(aiffMeta.channels, 2, "AIFF channels")
        c.expectClose(aiffMeta.durationSeconds ?? 0, 0.5, tolerance: 1e-6, "AIFF duration")
        c.expectEqual(aiffMeta.title, "Tape Loop", "AIFF NAME")
        c.expectEqual(aiffMeta.artist, "Archivist", "AIFF AUTH")
        c.expectEqual(aiffMeta.comment, "24-bit 96 kHz AIFF", "AIFF ANNO")

        // 7. Deterministic toJSON() round-trip and unknown/empty safety.
        let json1 = flacMeta.toJSON()
        let serialized1 = json1.serialized
        let serialized2 = flacMeta.toJSON().serialized
        c.expectEqual(serialized1, serialized2, "toJSON().serialized is deterministic")
        let reparsed = try JSON.parse(serialized1)
        c.expectEqual(reparsed, json1, "JSON.parse round-trip matches original JSON value")
        if let restored = AudioMetadata(json: reparsed) {
            var expectedNoArt = flacMeta
            expectedNoArt.artwork = nil
            c.expectEqual(restored, expectedNoArt, "AudioMetadata(json:) restores all metadata fields identically")
        } else {
            c.fail("AudioMetadata(json:) returned nil")
        }

        let emptyMeta = AudioMetadataParser.parse([])
        c.expectEqual(emptyMeta.format, .unknown, "empty bytes parse as .unknown safely")
        c.expectEqual(emptyMeta.title, nil, "empty bytes leave title nil")

        c.note("verified FLAC, ID3v2.3, ID3v2.4, MP4/ALAC, WAV, AIFF, and deterministic JSON (\(serialized1.utf8.count) bytes)")
    },
]
