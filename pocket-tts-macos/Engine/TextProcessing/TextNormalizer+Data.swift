//
//  TextNormalizer+Data.swift
//  pocket-tts-macos
//
//  Abbreviations, currency, fractions, symbols, and spoken acronyms
//  for text normalization.

import Foundation

extension TextNormalizer {

    // MARK: - Abbreviations

    nonisolated static let abbreviations: [String: String] = [
        "Dr.": "Doctor", "Mr.": "Mister", "Mrs.": "Missus", "Ms.": "Miss",
        "Jr.": "Junior", "Sr.": "Senior", "Prof.": "Professor",
        "Gen.": "General", "Gov.": "Governor", "Sgt.": "Sergeant",
        "Cpl.": "Corporal", "LCpl.": "Lance Corporal", "Lt.": "Lieutenant",
        "Col.": "Colonel", "Capt.": "Captain", "Cmdr.": "Commander",
        "Adm.": "Admiral", "Rev.": "Reverend", "St.": "Saint",
        "Ave.": "Avenue", "Blvd.": "Boulevard", "Dept.": "Department",
        "Govt.": "Government", "Inc.": "Incorporated", "Corp.": "Corporation",
        "Ltd.": "Limited", "Co.": "Company", "vs.": "versus",
        "etc.": "etcetera", "approx.": "approximately", "est.": "estimated",
        "min.": "minimum", "max.": "maximum", "avg.": "average",
        "no.": "number",
        "Jan.": "January", "Feb.": "February", "Mar.": "March",
        "Apr.": "April", "Jun.": "June", "Jul.": "July", "Aug.": "August",
        "Sep.": "September", "Sept.": "September", "Oct.": "October",
        "Nov.": "November", "Dec.": "December",
    ]

    // MARK: - Currency

    nonisolated static let currencyNames: [Character: (String, String)] = [
        "$": ("dollar", "dollars"),
        "€": ("euro", "euros"),
        "£": ("pound", "pounds"),
    ]

    // MARK: - Fractions

    nonisolated static let fractionNames: [[Int]: String] = [
        [1, 2]: "one half",
        [1, 3]: "one third", [2, 3]: "two thirds",
        [1, 4]: "one quarter", [3, 4]: "three quarters",
        [1, 5]: "one fifth",
        [1, 8]: "one eighth", [3, 8]: "three eighths",
        [5, 8]: "five eighths", [7, 8]: "seven eighths",
    ]

    // MARK: - Symbols

    nonisolated static let symbols: [String: String] = [
        "=": "equals", "+": "plus", "&": "and", "@": "at", "#": "number",
    ]

    // MARK: - Spoken acronyms (left as-is, not spelled out)

    nonisolated static let spokenAcronyms: Set<String> = [
        "NASA", "NATO", "ASAP", "LASER", "RADAR", "SCUBA",
        "LIDAR", "SONAR", "FLIR", "NADIR", "OK",
        "TARS", "PSHS", "GSHS",
    ]
}
