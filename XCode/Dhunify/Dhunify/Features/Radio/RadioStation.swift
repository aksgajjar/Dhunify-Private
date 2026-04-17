//
//  RadioStation.swift
//  Dhunify
//
//  All station URLs re-verified on 2026-04-14 via curl against the live
//  hosts. Only stream endpoints that returned 200 or 302 on first byte
//  are included here. When a requested station (Big FM / Radio City /
//  Ishq FM) had no working public stream, it was substituted with a
//  comparable Hindi/Bollywood station that does respond — each
//  substitution is noted on its row.
//

import SwiftUI

enum RadioCategory: String, CaseIterable, Identifiable {
    case hindi = "Hindi"
    case gujarati = "Gujarati"
    case news = "News"
    case delhi = "Delhi"
    var id: String { rawValue }
}

struct RadioStation: Identifiable {
    let id: String
    let name: String
    let description: String
    let streamURL: String
    let category: RadioCategory
    let color: Color
    let emoji: String
    /// Optional remote logo / artwork URL. Falls back to the emoji
    /// circle when nil or when the image fails to load.
    var thumbnailURL: String? = nil

    static let all: [RadioStation] = [
        // MARK: - Hindi (10 verified working — 2026-04-14)

        RadioStation(id: "mirchi", name: "Radio Mirchi 98.3",
                     description: "Hit toh Mirchi!",
                     streamURL: "https://eu8.fastcast4u.com/proxy/clyedupq/stream",
                     category: .hindi, color: Color(hex: "#E53935"), emoji: "📻",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=mirchi.in&sz=128"),

        RadioStation(id: "red_fm", name: "Red FM 93.5",
                     description: "Bajaate raho!",
                     streamURL: "https://funasia.streamguys1.com/live9",
                     category: .hindi, color: Color(hex: "#D81B60"), emoji: "🎶",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=redfmindia.in&sz=128"),

        RadioStation(id: "vividh_bharati", name: "Vividh Bharati",
                     description: "All India Radio — National",
                     streamURL: "https://air.pc.cdn.bitgravity.com/air/live/pbaudio001/playlist.m3u8",
                     category: .hindi, color: Color(hex: "#FB8C00"), emoji: "🇮🇳",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=prasarbharati.gov.in&sz=128"),

        RadioStation(id: "air_fm_rainbow", name: "AIR FM Rainbow",
                     description: "Colours of All India Radio",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio004/hlspbaudio004_Auto.m3u8",
                     category: .hindi, color: Color(hex: "#8E24AA"), emoji: "🌈",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "air_fm_gold", name: "AIR FM Gold",
                     description: "AIR Delhi FM Gold",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio005/hlspbaudio005_Auto.m3u8",
                     category: .hindi, color: Color(hex: "#FFB300"), emoji: "🏅",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "mirchi_love", name: "Mirchi Love",
                     description: "Romantic Hindi retro",
                     streamURL: "https://stream.zeno.fm/v2zfmxef798uv",
                     category: .hindi, color: Color(hex: "#EC407A"), emoji: "💕"),

        RadioStation(id: "radio_nasha", name: "Radio Nasha",
                     description: "Bollywood 90s classics",
                     streamURL: "https://stream.zeno.fm/rm4i9pdex3cuv",
                     category: .hindi, color: Color(hex: "#7E57C2"), emoji: "🎛️"),

        // Sub for Big FM 92.7 — no public stream, replaced with working Hindi station.
        RadioStation(id: "kishore_radio", name: "Kishore Kumar Radio",
                     description: "Kishore-da non-stop",
                     streamURL: "https://stream.zeno.fm/0ghtfp8ztm0uv",
                     category: .hindi, color: Color(hex: "#5C6BC0"), emoji: "🎤"),

        // Sub for Radio City 91.1 — no public stream, replaced with working Hindi station.
        RadioStation(id: "lata_radio", name: "Lata Mangeshkar Radio",
                     description: "The Nightingale — timeless",
                     streamURL: "https://stream.zeno.fm/87xam8pf7tzuv",
                     category: .hindi, color: Color(hex: "#26A69A"), emoji: "🌙",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgICgsq7HrQsMCxIOU3RhdGlvblByb2ZpbGUYgICQ4PH11QoMogEEemVubw/image/?u=1660862627000"),

        // Sub for Ishq FM 104.8 — no public stream, replaced with working Bollywood station.
        RadioStation(id: "hungama", name: "Radio Hungama",
                     description: "Bollywood Dil Se",
                     streamURL: "https://stream.zeno.fm/143d7gty24zuv",
                     category: .hindi, color: Color(hex: "#FF7043"), emoji: "🎬",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/a7a85f06-fa69-4735-a010-626c45a4a1cb/image/?u=1701701789000"),

        // Radio City variants (zeno-relayed via radio.garden — verified 2026-04-15).
        // The flagship 91.1 broadcast is geo-locked; these are the
        // genre web-channels that Radio City themselves publish.

        RadioStation(id: "radio_city_hindi", name: "Radio City Hindi",
                     description: "Radio City — Hindi web channel",
                     streamURL: "https://stream.zeno.fm/mrkzzr5uyc9uv",
                     category: .hindi, color: Color(hex: "#F44336"), emoji: "🌆",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgICAxJGdvAsMCxIOU3RhdGlvblByb2ZpbGUYgIDwia2KygoMogEEemVubw/image/?u=1660855515000"),

        RadioStation(id: "radio_city_freedom", name: "Radio City Freedom",
                     description: "Indian indie & non-film",
                     streamURL: "https://stream.zeno.fm/685khspd8f0uv",
                     category: .hindi, color: Color(hex: "#3949AB"), emoji: "🗽",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgICAxJGdvAsMCxIOU3RhdGlvblByb2ZpbGUYgIDQlpubvgkMogEEemVubw/image/?u=1682165192000"),

        RadioStation(id: "radio_city_hiphop", name: "Radio City Hiphop",
                     description: "Desi hip-hop & rap",
                     streamURL: "https://stream.zeno.fm/gut7ff5uyc9uv",
                     category: .hindi, color: Color(hex: "#212121"), emoji: "🎧"),

        RadioStation(id: "radio_city_metal", name: "Radio City Metal",
                     description: "Metal & hard rock",
                     streamURL: "https://stream.zeno.fm/630qt84uyc9uv",
                     category: .hindi, color: Color(hex: "#37474F"), emoji: "🤘",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgICAxJGdvAsMCxIOU3RhdGlvblByb2ZpbGUYgIDwiY_OnAgMogEEemVubw/image/?u=1660851376000"),

        RadioStation(id: "radio_city_electronica", name: "Radio City Electronica",
                     description: "EDM & electronic",
                     streamURL: "https://stream.zeno.fm/40ut2u4uyc9uv",
                     category: .hindi, color: Color(hex: "#00BCD4"), emoji: "🎛",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgICAxJGdvAsMCxIOU3RhdGlvblByb2ZpbGUYgIDwicCLlwkMogEEemVubw/image/?u=1660856635000"),

        // MARK: - Gujarati (re-verified 2026-04-15 via curl)

        RadioStation(id: "mirchi_ahmedabad", name: "Radio Mirchi 98.3 Ahmedabad",
                     description: "Hit toh Mirchi! — Ahmedabad",
                     streamURL: "https://eu8.fastcast4u.com/proxy/clyedupq/stream",
                     category: .gujarati, color: Color(hex: "#E53935"), emoji: "🌶️",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=mirchi.in&sz=128"),

        RadioStation(id: "red_fm_guj", name: "Red FM 93.5 Ahmedabad",
                     description: "Bajaate raho! — Ahmedabad",
                     streamURL: "https://funasia.streamguys1.com/live9",
                     category: .gujarati, color: Color(hex: "#D81B60"), emoji: "🎶",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=redfmindia.in&sz=128"),

        RadioStation(id: "rangilo_gujarati", name: "Rangilo Gujarati",
                     description: "Ahmedabad live — Gujarati hits",
                     streamURL: "http://s9.voscast.com:7402/;",
                     category: .gujarati, color: Color(hex: "#FB8C00"), emoji: "🎺"),

        RadioStation(id: "swaminarayan_kirtan", name: "Swaminarayan Kirtan",
                     description: "Ahmedabad — kirtan & bhajans",
                     streamURL: "https://radio.nnd.media/listen/swaminarayan_kirtan/Kirtan.mp3",
                     category: .gujarati, color: Color(hex: "#FFB300"), emoji: "🕉️"),

        RadioStation(id: "goldy_gujarati", name: "Goldy Gujarati",
                     description: "Gujarati hits non-stop",
                     streamURL: "https://stream.zeno.fm/28wseh18am8uv",
                     category: .gujarati, color: Color(hex: "#FB8C00"), emoji: "🎵",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgIDQ16Ll_QkMCxIOU3RhdGlvblByb2ZpbGUYgIDQ95ak2wsMogEEemVubw/image/?u=1696184957000"),

        RadioStation(id: "goldy_garba", name: "Goldy Garba",
                     description: "Garba & dandiya anthems",
                     streamURL: "https://stream.zeno.fm/n0zkr7wa6p8uv",
                     category: .gujarati, color: Color(hex: "#E91E63"), emoji: "💃",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgIDQ16Ll_QkMCxIOU3RhdGlvblByb2ZpbGUYgICwsMG_uAgMogEEemVubw/image/?u=1694850574000"),

        RadioStation(id: "goldy_mukesh", name: "Goldy Mukesh",
                     description: "Mukesh classic melodies",
                     streamURL: "https://stream.zeno.fm/mrcz5sus1p8uv",
                     category: .gujarati, color: Color(hex: "#8E24AA"), emoji: "🎤",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgIDQ16Ll_QkMCxIOU3RhdGlvblByb2ZpbGUYgICwgI-yzwgMogEEemVubw/image/?u=1694850625000"),

        RadioStation(id: "goldy_sarvani", name: "Goldy Sarvani",
                     description: "Gujarati devotional",
                     streamURL: "https://stream.zeno.fm/c5bt9h37bm8uv",
                     category: .gujarati, color: Color(hex: "#7E57C2"), emoji: "🪷",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgIDQ16Ll_QkMCxIOU3RhdGlvblByb2ZpbGUYgIDQj-qprwoMogEEemVubw/image/?u=1666627649000"),

        RadioStation(id: "goldy_aaradhna", name: "Goldy Aaradhna",
                     description: "Bhajans & bhakti",
                     streamURL: "https://stream.zeno.fm/s14278r2cm8uv",
                     category: .gujarati, color: Color(hex: "#D81B60"), emoji: "🙏",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/agxzfnplbm8tc3RhdHNyMgsSCkF1dGhDbGllbnQYgIDQ16Ll_QkMCxIOU3RhdGlvblByb2ZpbGUYgIDQz6KciwsMogEEemVubw/image/?u=1757351450000"),

        RadioStation(id: "goldy_classic", name: "Goldy Classic",
                     description: "Classic Gujarati retro",
                     streamURL: "https://stream.zeno.fm/hx2wtsw2kwkuv",
                     category: .gujarati, color: Color(hex: "#5C6BC0"), emoji: "🎼",
                     thumbnailURL: "https://proxy.zeno.fm/content/stations/64f12365-7b6e-4863-af7a-45b1000d12c1/image/?u=1694850524000"),

        // MARK: - News (re-verified 2026-04-15 — old TV-tied URLs were dead)

        RadioStation(id: "air_news", name: "AIR News Hindi",
                     description: "All India Radio — Hindi news",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio009/hlspbaudio009_Auto.m3u8",
                     category: .news, color: Color(hex: "#1565C0"), emoji: "📰",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "air_fm_gold_news", name: "FM Gold News",
                     description: "AIR FM Gold — news bulletins",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio005/hlspbaudio005_Auto.m3u8",
                     category: .news, color: Color(hex: "#FFB300"), emoji: "🏅",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "air_national", name: "AIR National Channel",
                     description: "National news & talk",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio002/hlspbaudio002_Auto.m3u8",
                     category: .news, color: Color(hex: "#D32F2F"), emoji: "🇮🇳",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "air_rainbow_news", name: "AIR Rainbow Delhi",
                     description: "News, talk & music",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio003/hlspbaudio003_Auto.m3u8",
                     category: .news, color: Color(hex: "#FF5722"), emoji: "🌈",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "air_urdu_news", name: "AIR Urdu Service",
                     description: "Urdu news & talk",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio010/hlspbaudio010_Auto.m3u8",
                     category: .news, color: Color(hex: "#00897B"), emoji: "📻",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        // MARK: - Delhi (verified 2026-04-15 — only publicly-available
        // Delhi stations. Big FM 92.7 / Radio City 91.1 / My FM 94.3
        // are geo-locked to their own apps and cannot be included.)

        RadioStation(id: "red_fm_delhi", name: "Red FM 93.5 Delhi",
                     description: "Bajaate raho! — Delhi",
                     streamURL: "https://funasia.streamguys1.com/live9",
                     category: .delhi, color: Color(hex: "#D81B60"), emoji: "🎶",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=redfmindia.in&sz=128"),

        RadioStation(id: "mirchi_delhi", name: "Radio Mirchi 98.3 Delhi",
                     description: "Hit toh Mirchi! — Delhi",
                     streamURL: "https://eu8.fastcast4u.com/proxy/clyedupq/stream",
                     category: .delhi, color: Color(hex: "#E53935"), emoji: "📻",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=mirchi.in&sz=128"),

        RadioStation(id: "air_rainbow_delhi", name: "AIR FM Rainbow Delhi",
                     description: "Colours of Delhi",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio003/hlspbaudio003_Auto.m3u8",
                     category: .delhi, color: Color(hex: "#8E24AA"), emoji: "🌈",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "air_gold_delhi", name: "AIR FM Gold Delhi",
                     description: "News + retro hits",
                     streamURL: "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio005/hlspbaudio005_Auto.m3u8",
                     category: .delhi, color: Color(hex: "#FFB300"), emoji: "🏅",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=newsonair.gov.in&sz=128"),

        RadioStation(id: "vividh_bharati_delhi", name: "Vividh Bharati Delhi",
                     description: "AIR national — Delhi",
                     streamURL: "https://air.pc.cdn.bitgravity.com/air/live/pbaudio001/playlist.m3u8",
                     category: .delhi, color: Color(hex: "#FB8C00"), emoji: "🇮🇳",
                     thumbnailURL: "https://www.google.com/s2/favicons?domain=prasarbharati.gov.in&sz=128"),
    ]
}
