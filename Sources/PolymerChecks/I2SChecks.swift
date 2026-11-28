// Checks for I2SCore: the library model ported from Meimei.
import PolymerBase
import I2SCore
import I2S

private func sampleTrack(_ id: String, _ title: String, album: String, artist: String = "Artist",
                         no: Int? = nil, disc: Int? = nil, year: Int? = nil, art: String? = nil) -> Track {
    Track(id: id, filePath: "C:/Music/\(id).flac", title: title, artist: artist, album: album,
          year: year, trackNumber: no, discNumber: disc, duration: 100.5, sampleRate: 44100,
          bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 900, fileFormat: "FLAC", artworkFilePath: art)
}

@MainActor let i2sChecks: [Check] = [
    Check("i2s.natural-order") { c in
        c.expect("Track 2".naturallyPrecedes("Track 10"), "2 before 10")
        c.expect("abc".naturallyPrecedes("ABD"), "case ignored")
        c.expectEqual("a01".naturalCompare("a1"), 0, "leading zeros")
        c.expect("a".naturallyPrecedes("a1"), "prefix first")
        c.expectEqual(formatClock(seconds: 187.9), "3:07")
        c.expectEqual(formatClock(seconds: 3723), "1:02:03")
        c.expectEqual(formatClock(seconds: -1), "0:00")
        c.expectEqual(formatSampleRate(44100), "44.1 kHz")
        c.expectEqual(formatSampleRate(48000), "48 kHz")
    },

    Check("i2s.track.json") { c in
        let t = sampleTrack("A", "One", album: "Rec", no: 1, year: 1999, art: "a.png")
        let text = t.json.serialized
        guard let parsed = try? JSON.parse(text), let back = Track(json: parsed) else { c.fail("round trip failed"); return }
        c.expectEqual(back, t, "round trip")
        // Older files: only the required keys.
        let old: JSON = ["id": "X", "filePath": "p", "title": "t", "artist": "a", "album": "b", "albumArtist": "a",
                         "genre": "g", "duration": 1, "sampleRate": 44100, "bitDepth": 16, "channelCount": 2,
                         "estimatedBitrateKbps": 128, "fileFormat": "MP3"]
        let o = Track(json: old)
        c.expectEqual(o?.playCount, 0, "default play count")
        c.expectEqual(o?.liked, false, "default liked")
        c.expectEqual(o?.composer, "", "default composer")
        c.expect(Track(json: ["id": "X"]) == nil, "missing required fields")
        c.expect(t.json["year"] != nil && sampleTrack("B", "t", album: "b").json["year"] == nil, "nil values left out")
        c.expectEqual(t.qualitySummary, "44.1 kHz · 16-bit")
        c.expect(!t.isHiRes, "CD quality is not hi-res")
    },

    Check("i2s.albums") { c in
        let tracks = [
            sampleTrack("1", "Two", album: "Rec", no: 2, year: 2001),
            sampleTrack("2", "One", album: "Rec", no: 1, art: "rec.png"),
            sampleTrack("3", "Solo", album: "Alpha", artist: "Other"),
            sampleTrack("4", "Nameless", album: ""),
            sampleTrack("5", "B1", album: "Rec", no: 1, disc: 2),
        ]
        let groups = AlbumGroup.groups(from: tracks)
        c.expectEqual(groups.map(\.title), ["Alpha", "Rec", "Unknown Album"], "sorted by title")
        let rec = groups[1]
        c.expectEqual(rec.trackCount, 3, "tracks in Rec")
        c.expectEqual(rec.year, 2001, "first year found")
        c.expectEqual(rec.artworkFilePath, "rec.png", "first artwork found")
        c.expectClose(rec.duration, 301.5, tolerance: 0.001, "total duration")
        let ordered = tracks.filter { $0.album == "Rec" }.sorted(by: Track.albumOrder).map(\.title)
        c.expectEqual(ordered, ["One", "Two", "B1"],
                      "disc then track order (no disc sorts first)")
    },
]

@MainActor let i2sLibraryChecks: [Check] = [
    Check("i2s.library.rows") { c in
        let ts = [
            sampleTrack("1", "A", album: "Rec", year: 1999), sampleTrack("2", "B", album: "Rec", year: 1999),
            sampleTrack("3", "C", album: "Alpha", year: 2010),
        ]
        let rows = LibraryRow.build(from: ts, groupBy: .album)
        c.expectEqual(rows.count, 5, "two headers and three tracks")
        if case .header(let t, let d) = rows[0] { c.expectEqual(t, "Alpha"); c.expectEqual(d, "1 track · 1:40") } else { c.fail("header first") }
        if case .track(_, let s) = rows[4] { c.expect(s, "second track in group is striped") } else { c.fail("track") }
        if case .header(let t, _) = LibraryRow.build(from: ts, groupBy: .year)[0] { c.expectEqual(t, "2010", "years newest first") }
        c.expectEqual(LibraryRow.build(from: ts, groupBy: .none).count, 3)
    },
    Check("i2s.library.file") { c in
        let text = """
        {"tracks":[{"id":"1","filePath":"p","title":"T","artist":"A","album":"B","albumArtist":"A","genre":"g",
        "duration":10,"sampleRate":44100,"bitDepth":16,"channelCount":2,"estimatedBitrateKbps":1,"fileFormat":"FLAC","playCount":9}],
        "playlists":[{"id":"P","name":"Mix","trackIDs":["1"]},{"id":"L","name":"All","isLibraryView":true}]}
        """
        guard let f = try? LibraryFile.read(text) else { c.fail("parse"); return }
        c.expectEqual(f.tracks.count, 1); c.expectEqual(f.tracks[0].playCount, 0, "counts ignored")
        c.expectEqual(f.playlists.map(\.name), ["Mix"], "library view dropped")
        let back = try? LibraryFile.read(f.encoded())
        c.expectEqual(back?.tracks, f.tracks, "round trip")
        let shown = LibraryRules.base(for: .playlist("P"), tracks: f.tracks, now: 0) { id in f.playlists.first { $0.id == id } }
        c.expectEqual(shown.count, 1, "playlist contents")
        c.expectEqual(LibraryRules.filter(f.tracks, by: "t a").count, 1, "all words")
        c.expectEqual(LibraryRules.filter(f.tracks, by: "zzz").count, 0)
        c.expectEqual(LibrarySource(key: "genre:Rock"), .genre("Rock"))
    },
]

@MainActor let i2sRulesChecks: [Check] = [
    Check("i2s.smart-playlist") { c in
        var a = sampleTrack("a", "Dawn", album: "X", year: 2001); a.genre = "Rock"; a.liked = true; a.playCount = 5
        var b = sampleTrack("b", "Dusk", album: "X", year: 2010); b.genre = "Jazz"; b.playCount = 9
        var p = Playlist(id: "P", name: "S"); p.isSmart = true
        p.setRules([SmartRule(id: "1", field: .genre, op: .contains, value: "ROC")])
        c.expectEqual(p.resolveSmart(from: [a, b], now: 0).map(\.id), ["a"], "text contains, case folded")
        p.setRules([SmartRule(id: "1", field: .duration, op: .equals, value: "1")])
        c.expectEqual(p.resolveSmart(from: [a, b], now: 0).count, 2, "length is 1 matches 1:40")
        p.setRules([SmartRule(id: "1", field: .liked, op: .isTrue), SmartRule(id: "2", field: .year, op: .gte, value: "2005")])
        c.expectEqual(p.resolveSmart(from: [a, b], now: 0).count, 0, "all rules")
        p.matchAll = false
        c.expectEqual(p.resolveSmart(from: [a, b], now: 0).count, 2, "any rule")
        p.smartOrder = "mostPlayed"; p.smartLimit = 1
        c.expectEqual(p.resolveSmart(from: [a, b], now: 0).map(\.id), ["b"], "order then limit")
        let back = Playlist(json: p.json)
        c.expectEqual(back?.rules, p.rules, "rules round trip")
        var empty = p; empty.setRules([])
        c.expectEqual(empty.resolveSmart(from: [a, b], now: 0).count, 0, "no rules matches nothing")
    },
    Check("i2s.lyrics") { c in
        let r = Lyrics.read("[00:01.50]One\n[00:03]<00:03.00>Two\n[00:01.50][00:10.5]Again")
        c.expect(r.synced, "synced")
        c.expectEqual(r.lines.map(\.text), ["One", "Again", "Two", "Again"], "sorted, stable, multi-stamp")
        c.expectEqual(Lyrics.currentIndex(in: r.lines, at: 0.5), nil, "before first")
        c.expectEqual(Lyrics.currentIndex(in: r.lines, at: 3.2), 2)
        let plain = Lyrics.read("a\r\n b \n\n")
        c.expect(!plain.synced && plain.lines.map(\.text) == ["a", "b"], "plain trimmed")
    },
    Check("i2s.duplicates") { c in
        var x = sampleTrack("1", "Song!", album: "Rec", artist: "Ann"); x.duration = 100
        var y = sampleTrack("2", "song", album: "Rec (Deluxe)", artist: "ann"); y.duration = 100.9
        c.expectEqual(x.duplicateSongKey, y.duplicateSongKey, "same song across files")
        c.expectEqual(DuplicateIdentity.normalize("  A--b  C "), "a b c")
        c.expectEqual(DuplicateFinder.groups(in: [x, y]).count, 1, "one song group")
        var z = x; z.id = "3"; z.filePath = "other"; z.artworkFilePath = nil
        c.expectEqual(DuplicateFinder.groups(in: [x, z]).first?.subtitle, "Ann · 2 copies")
    },
]

@MainActor let i2sSettingsChecks: [Check] = [
    Check("i2s.settings") { c in
        let s = AppSettingsData.decodeLeniently(from: "{\"density\":\"spacious\",\"spectrumStyle\":\"neon\",\"crossfadeSeconds\":2.5,\"layoutPreset\":\"old\"}")
        c.expectEqual(s.density, .spacious, "known value kept")
        c.expectEqual(s.crossfadeSeconds, 2.5, "number kept")
        c.expectEqual(s.spectrumStyle, AppSettingsData().spectrumStyle, "unknown value falls back")
        c.expect(AppSettingsData.decodeLeniently(from: "{}") == AppSettingsData(), "empty is defaults")
        c.expect(AppSettingsData.decodeLeniently(from: "[]") == AppSettingsData(), "not an object is defaults")
        let again = AppSettingsData.decodeLeniently(from: s.encoded)
        c.expect(again == s, "round trip")
        c.expectEqual(AppFontFamily.allCases.count, 10, "font families")
        c.expectEqual(OnlineSource.allCases.map(\.rawValue), ["appleMusic", "musicBrainz", "deezer"])
    },
]

@MainActor let i2sAppChecks: [Check] = [
    Check("i2s.app.model") { c in
        let m = I2SModel(tracks: I2SSample.tracks())
        c.expectEqual(m.albums.count, 8, "sample albums")
        m.source = .liked
        c.expect(!m.visibleTracks.isEmpty && m.visibleTracks.allSatisfy(\.liked), "liked source")
        m.source = .all; m.filter = "afterglow"
        c.expect(!m.visibleTracks.isEmpty && m.visibleTracks.allSatisfy { $0.title.contains("Afterglow") }, "filter")
        m.filter = ""
        m.togglePlay()
        c.expect(m.isPlaying && m.nowPlaying != nil, "play starts first track")
        let first = m.nowPlayingID
        m.step(1)
        c.expect(m.nowPlayingID != first, "next track")
        m.step(-1)
        c.expectEqual(m.nowPlayingID, first, "previous track")
    },
]

@MainActor let i2sThemeChecks: [Check] = [
    Check("i2s.theme-generator") { c in
        c.expect(ThemeGenerator.generate(name: "x", colors: [1, 2, 3, 4, 5, 6, 7]) == nil, "7 colours must give nil")
        c.expectEqual(ThemeGenerator.parseHexList("#ff0000, 00ff00 0x0000FF #abc"), [0xFF0000, 0x00FF00, 0x0000FF])
        let cols: [UInt32] = [0x101418, 0x1C2128, 0x2A3038, 0x8899AA, 0xC8D0D8, 0xF4F6F8, 0xE0457B, 0x45C4E0]
        if let t = ThemeGenerator.generate(name: "t", colors: cols) {
            c.expect(ThemeGenerator.contrast(t.textPrimary, t.bgVoid) >= 11, "text contrast")
            c.expect(ThemeGenerator.contrast(t.accent, t.bgVoid) >= 3, "accent contrast")
        } else { c.fail("generate returned nil for 8 colours") }
    },
    Check("i2s.themes") { c in
        let s = CustomTheme.starterThemes
        c.expectEqual(s.count, 15)
        c.expectEqual(Set(s.map { $0.id }).count, 15, "unique ids")
        c.expectEqual(CustomTheme.list(json: CustomTheme.json(s)) ?? [], s, "json round trip")
        c.expectEqual(Palette.all.count, 15)
        c.expectEqual(ThemeLibrary.merged([]), s)
    },
    Check("i2s.metadata-cleanup") { c in
        c.expectEqual(MetadataCleanup.featuring("Song  ft Drake", .parentheses), "Song (feat. Drake)")
        c.expectEqual(MetadataCleanup.featuring("Song [Featuring The Weeknd]", .parentheses), "Song (feat. The Weeknd)")
        c.expectEqual(MetadataCleanup.removingEditionTags("Heroes (2017 Remaster)"), "Heroes")
        c.expectEqual(MetadataCleanup.removingEditionTags("Heroes (Live)"), "Heroes (Live)")
        c.expectEqual(ArtistSpellings.key("Beyoncé"), ArtistSpellings.key("BEYONCE"))
    },
    Check("i2s.equalizer") { c in
        c.expectEqual(EQProfile.builtIns.count, 15)
        if let p = ParametricEQText.parse("Preamp: -6.2 dB\nFilter 1: ON PK Fc 105 Hz Gain 4.5 dB Q 0.70", name: "x") {
            c.expectClose(p.preampGain, -6.2, tolerance: 1e-9)
            c.expectEqual(p.bands.count, 1)
            c.expectClose(p.bands.first?.frequency ?? 0, 105, tolerance: 1e-9)
        } else { c.fail("parse failed") }
    },
]
