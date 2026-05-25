//
//  TextNormalizer+Units.swift
//  pocket-tts-macos
//
//  Unit dictionaries for text normalization. Values are (singular, plural)
//  tuples to handle irregular plurals correctly.

import Foundation

extension TextNormalizer {

    // MARK: - Units (number + unit → expanded form)

    nonisolated static let units: [String: (String, String)] = [
        // Length
        "mm": ("millimeter", "millimeters"),
        "cm": ("centimeter", "centimeters"),
        "m": ("meter", "meters"),
        "km": ("kilometer", "kilometers"),
        "in": ("inch", "inches"),
        "ft": ("foot", "feet"),
        "yd": ("yard", "yards"),
        "mi": ("mile", "miles"),
        "nm": ("nanometer", "nanometers"),
        "um": ("micrometer", "micrometers"),
        "pm": ("picometer", "picometers"),
        "au": ("astronomical unit", "astronomical units"),
        "ly": ("light-year", "light-years"),
        "pc": ("parsec", "parsecs"),
        "nmi": ("nautical mile", "nautical miles"),
        // Mass
        "mg": ("milligram", "milligrams"),
        "g": ("gram", "grams"),
        "kg": ("kilogram", "kilograms"),
        "lb": ("pound", "pounds"),
        "lbs": ("pound", "pounds"),
        "oz": ("ounce", "ounces"),
        "ug": ("microgram", "micrograms"),
        "st": ("stone", "stone"),
        // Volume
        "ml": ("milliliter", "milliliters"),
        "l": ("liter", "liters"),
        "gal": ("gallon", "gallons"),
        "qt": ("quart", "quarts"),
        "pt": ("pint", "pints"),
        "cl": ("centiliter", "centiliters"),
        "dl": ("deciliter", "deciliters"),
        "hl": ("hectoliter", "hectoliters"),
        // Speed
        "mph": ("mile per hour", "miles per hour"),
        "kph": ("kilometer per hour", "kilometers per hour"),
        "fps": ("foot per second", "feet per second"),
        "mps": ("meter per second", "meters per second"),
        // Temperature
        "°C": ("degree Celsius", "degrees Celsius"),
        "°F": ("degree Fahrenheit", "degrees Fahrenheit"),
        // Data (lowercase b = bits; uppercase B handled at runtime)
        "kb": ("kilobit", "kilobits"),
        "mb": ("megabit", "megabits"),
        "gb": ("gigabit", "gigabits"),
        "tb": ("terabit", "terabits"),
        "kbps": ("kilobit per second", "kilobits per second"),
        "mbps": ("megabit per second", "megabits per second"),
        "gbps": ("gigabit per second", "gigabits per second"),
        // Time
        "ms": ("millisecond", "milliseconds"),
        "ns": ("nanosecond", "nanoseconds"),
        "ps": ("picosecond", "picoseconds"),
        "us": ("microsecond", "microseconds"),
        "hz": ("hertz", "hertz"),
        "khz": ("kilohertz", "kilohertz"),
        "mhz": ("megahertz", "megahertz"),
        "ghz": ("gigahertz", "gigahertz"),
        // Power / Electrical
        "w": ("watt", "watts"),
        "kw": ("kilowatt", "kilowatts"),
        "mw": ("megawatt", "megawatts"),
        "gw": ("gigawatt", "gigawatts"),
        "hp": ("horsepower", "horsepower"),
        "v": ("volt", "volts"),
        "kv": ("kilovolt", "kilovolts"),
        "ma": ("milliamp", "milliamps"),
        "db": ("decibel", "decibels"),
        // Angle
        "deg": ("degree", "degrees"),
        "rad": ("radian", "radians"),
        // Pressure
        "pa": ("pascal", "pascals"),
        "hpa": ("hectopascal", "hectopascals"),
        "kpa": ("kilopascal", "kilopascals"),
        "mpa": ("megapascal", "megapascals"),
        "bar": ("bar", "bar"),
        "mbar": ("millibar", "millibar"),
        "atm": ("atmosphere", "atmospheres"),
        "torr": ("torr", "torr"),
        "mmhg": ("millimeter of mercury", "millimeters of mercury"),
        "inhg": ("inch of mercury", "inches of mercury"),
        // Area
        "m²": ("square meter", "square meters"),
        "km²": ("square kilometer", "square kilometers"),
        "ft²": ("square foot", "square feet"),
        "mi²": ("square mile", "square miles"),
        "sqft": ("square foot", "square feet"),
        "sqm": ("square meter", "square meters"),
        // Volume (extended)
        "m³": ("cubic meter", "cubic meters"),
        "km³": ("cubic kilometer", "cubic kilometers"),
        "ft³": ("cubic foot", "cubic feet"),
        // Misc
        "rpm": ("revolution per minute", "revolutions per minute"),
        "psi": ("pound per square inch", "pounds per square inch"),
        // Concentration
        "ppm": ("part per million", "parts per million"),
        "ppb": ("part per billion", "parts per billion"),
        "ppt": ("part per trillion", "parts per trillion"),
        "ppq": ("part per quadrillion", "parts per quadrillion"),
        // ISR / Radar / Physics
        "dbm": ("decibel-milliwatt", "decibel-milliwatts"),
        "dbi": ("decibel isotropic", "decibel isotropic"),
        "dbw": ("decibel-watt", "decibel-watts"),
        "dbsm": ("decibel square meter", "decibel square meters"),
        "dbc": ("decibel relative to carrier", "decibel relative to carrier"),
        "dbd": ("decibel relative to dipole", "decibel relative to dipole"),
        "dbr": ("decibel relative", "decibel relative"),
        "dbhz": ("decibel-hertz", "decibel-hertz"),
        "dbuv": ("decibel-microvolt", "decibel-microvolts"),
        "sr": ("steradian", "steradians"),
        "mrad": ("milliradian", "milliradians"),
        "urad": ("microradian", "microradians"),
        "kn": ("knot", "knots"),
        "kt": ("knot", "knots"),
    ]

    // MARK: - Data byte overrides (uppercase B = bytes)

    nonisolated static let dataByteOverrides: [String: (String, String)] = [
        "kb": ("kilobyte", "kilobytes"),
        "mb": ("megabyte", "megabytes"),
        "gb": ("gigabyte", "gigabytes"),
        "tb": ("terabyte", "terabytes"),
    ]

    // MARK: - Standalone units (no preceding number)

    nonisolated static let standaloneUnits: [String: String] = [
        "kg": "kilograms", "km": "kilometers", "mm": "millimeters",
        "cm": "centimeters", "nm": "nanometers", "um": "micrometers",
        "mg": "milligrams", "lb": "pounds", "lbs": "pounds", "oz": "ounces",
        "ml": "milliliters", "gal": "gallons",
        "mph": "miles per hour", "kph": "kilometers per hour",
        "fps": "feet per second", "mps": "meters per second",
        "kb": "kilobits", "mb": "megabits", "gb": "gigabits", "tb": "terabits",
        "kbps": "kilobits per second", "mbps": "megabits per second",
        "gbps": "gigabits per second",
        "ms": "milliseconds", "ns": "nanoseconds",
        "hz": "hertz", "khz": "kilohertz", "mhz": "megahertz", "ghz": "gigahertz",
        "kw": "kilowatts", "mw": "megawatts", "gw": "gigawatts",
        "kv": "kilovolts", "ma": "milliamps", "db": "decibels",
        "rpm": "revolutions per minute", "psi": "pounds per square inch",
        "sqft": "square feet", "sqm": "square meters",
        "dbm": "decibel-milliwatts", "dbi": "decibel isotropic",
        "dbw": "decibel-watts", "dbsm": "decibel square meters",
        "dbc": "decibel relative to carrier", "dbd": "decibel relative to dipole",
        "dbr": "decibel relative", "dbhz": "decibel-hertz",
        "dbuv": "decibel-microvolts",
        "hpa": "hectopascals", "kpa": "kilopascals", "mpa": "megapascals",
        "mbar": "millibar", "atm": "atmospheres", "torr": "torr",
        "mmhg": "millimeters of mercury", "inhg": "inches of mercury",
        "ppm": "parts per million", "ppb": "parts per billion",
        "ppt": "parts per trillion", "ppq": "parts per quadrillion",
        "nmi": "nautical miles", "mrad": "milliradians",
    ]
}
