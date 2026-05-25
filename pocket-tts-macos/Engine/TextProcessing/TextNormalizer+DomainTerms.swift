//
//  TextNormalizer+DomainTerms.swift
//  pocket-tts-macos
//
//  Domain-specific terms: ISR, radar, EOIR, remote sensing, systems
//  engineering (DoDAF, SysML, UML), project management, space systems,
//  astrodynamics, propulsion, and comms/link budget.
//
//  These get explicit spoken forms rather than generic letter-by-letter
//  spelling. Ported from pocket_tts/text_normalizer.py.

import Foundation

extension TextNormalizer {

    // MARK: - Domain terms

    nonisolated static let domainTerms: [String: String] = [
        // Intelligence disciplines
        "ISR": "I.S.R.", "SIGINT": "sig-int", "ELINT": "ee-lint",
        "COMINT": "com-int", "MASINT": "may-zint", "GEOINT": "gee-oh-int",
        "HUMINT": "hue-mint", "OSINT": "oh-sint", "IMINT": "im-int",
        "TECHINT": "tech-int",
        // Sensor / imaging
        "EOIR": "electro-optical infrared", "EO": "electro-optical",
        "IR": "infrared", "SAR": "synthetic aperture radar",
        "ISAR": "inverse synthetic aperture radar",
        "MTI": "moving target indicator", "GMTI": "ground moving target indicator",
        "AMTI": "airborne moving target indicator",
        "MWIR": "mid-wave infrared", "LWIR": "long-wave infrared",
        "SWIR": "short-wave infrared", "VNIR": "visible near infrared",
        "NIR": "near infrared", "TIR": "thermal infrared",
        "HSI": "hyperspectral imaging", "MSI": "multispectral imaging",
        "PAN": "panchromatic", "FWHM": "full-width at half-maximum",
        // Radar
        "PRF": "pulse repetition frequency", "PRI": "pulse repetition interval",
        "RCS": "radar cross section", "SNR": "signal to noise ratio",
        "CNR": "contrast to noise ratio",
        "EIRP": "effective isotropic radiated power",
        "RF": "radio frequency", "IF": "intermediate frequency",
        "LO": "local oscillator", "FFT": "fast Fourier transform",
        "AGC": "automatic gain control", "ADC": "analog to digital converter",
        "DAC": "digital to analog converter", "HPA": "high power amplifier",
        "LPA": "low power amplifier",
        // Image quality / performance
        "NIIRS": "national imagery interpretability rating scale",
        "GIQE": "general image quality equation",
        "GSD": "ground sample distance", "IFOV": "instantaneous field of view",
        "FOV": "field of view", "GRD": "ground resolved distance",
        "SRD": "system requirements document", "RMS": "root mean square",
        "TIN": "triangulated irregular network",
        // Thermal / radiometry
        "NETD": "N.E.T.D.", "NEDT": "N.E.D.T.", "NED": "N.E.D.",
        // Geospatial
        "GIS": "G.I.S.", "DEM": "dem", "DSM": "D.S.M.", "DTM": "D.T.M.",
        "DTED": "D.T.E.D.", "UTM": "U.T.M.", "MGRS": "M.G.R.S.",
        "WGS": "W.G.S.",
        // Systems / comms
        "CONOP": "con-op", "BER": "B.E.R.", "BW": "bandwidth",
        "SATCOM": "sat-com", "MILSPEC": "mil-spec", "COTS": "cots",
        "SWaP": "swap", "SWAP": "swap",
        // RF / microwave spectral bands
        "HF": "H.F.", "VHF": "V.H.F.", "UHF": "U.H.F.",
        "L-band": "L band", "S-band": "S band", "C-band": "C band",
        "X-band": "X band", "Ku-band": "K.U. band", "K-band": "K band",
        "Ka-band": "kay-ay band", "V-band": "V band", "W-band": "W band",
        "Q-band": "Q band", "E-band": "E band", "D-band": "D band",
        "G-band": "G band",
        // Systems engineering
        "SE": "S.E.", "MBSE": "M.B.S.E.",
        "SETR": "systems engineering technical review",
        "INCOSE": "in-co-see", "SOI": "system of interest",
        "SOS": "system of systems", "SoS": "system of systems",
        // SE processes & concepts
        "RVTM": "requirements verification traceability matrix",
        "RTM": "requirements traceability matrix",
        "CONOPS": "con-ops", "ICD": "I.C.D.", "SRS": "S.R.S.",
        "SSS": "S.S.S.", "MOE": "measure of effectiveness",
        "MOP": "measure of performance", "MOS": "measure of suitability",
        "KPP": "key performance parameter", "KSA": "key system attribute",
        "TPM": "technical performance measure",
        "CDD": "capability development document",
        "CPD": "capability production document",
        "SOW": "statement of work", "SOO": "statement of objectives",
        "WBS": "work breakdown structure", "PBS": "product breakdown structure",
        "FBS": "functional breakdown structure", "BOM": "bill of materials",
        "FMEA": "F.M.E.A.", "FMECA": "F.M.E.C.A.",
        "FTA": "fault tree analysis", "RBD": "reliability block diagram",
        // SE reviews & milestones
        "ASR": "alternative systems review", "SFR": "system functional review",
        "SRR": "S.R.R.", "PDR": "P.D.R.", "CDR": "C.D.R.",
        "TRR": "test readiness review", "FCA": "functional configuration audit",
        "PCA": "physical configuration audit", "SVR": "system verification review",
        "PRR": "production readiness review", "MRR": "mission readiness review",
        "IBR": "integrated baseline review",
        "TRL": "technology readiness level", "MRL": "manufacturing readiness level",
        "IRL": "integration readiness level", "SRL": "system readiness level",
        // DoDAF views
        "DODAF": "doh-daf", "DoDAF": "doh-daf",
        "AV": "all view", "OV": "operational view", "SV": "systems view",
        "CV": "capability view", "DIV": "data and information view",
        "PV": "project view",
        // SysML / UML
        "SYSML": "sis-M.L.", "SysML": "sis-M.L.", "UML": "U.M.L.",
        "BDD": "block definition diagram", "IBD": "internal block diagram",
        "STM": "state machine diagram", "FFBD": "functional flow block diagram",
        "DFD": "data flow diagram", "ERD": "entity relationship diagram",
        "CIR": "canonical internal representation",
        // Modeling & architecture frameworks
        "TOGAF": "toe-gaf", "UAF": "U.A.F.", "UPDM": "U.P.D.M.",
        "MDA": "M.D.A.", "MOF": "M.O.F.", "XMI": "X.M.I.",
        "DMN": "D.M.N.", "BPMN": "B.P.M.N.",
        // V&V / test
        "VV": "V. and V.", "IV": "independent verification",
        "IVV": "independent verification and validation",
        "DT": "developmental test", "OT": "operational test",
        "IOC": "initial operational capability",
        "FOC": "full operational capability",
        "LRIP": "low-rate initial production", "FRP": "full-rate production",
        // Project management
        "PM": "program manager", "PMO": "program management office",
        "PMP": "project management professional",
        "IPT": "integrated product team",
        "EVM": "earned value management",
        "EVMS": "earned value management system",
        "CPI": "cost performance index", "SPI": "schedule performance index",
        "EAC": "estimate at completion", "ETC": "estimate to complete",
        "BAC": "budget at completion", "BOE": "basis of estimate",
        "BCWS": "budgeted cost of work scheduled",
        "BCWP": "budgeted cost of work performed",
        "ACWP": "actual cost of work performed",
        "POAM": "plan of action and milestones",
        "ROI": "return on investment", "IRR": "internal rate of return",
        "NPV": "net present value", "LOE": "level of effort",
        "IMP": "integrated master plan", "IMS": "integrated master schedule",
        "CDRL": "contract data requirements list",
        "DID": "data item description",
        "RFP": "request for proposal", "RFI": "request for information",
        "RFQ": "request for quote", "CLIN": "contract line item number",
        "NTE": "not to exceed", "FFP": "firm fixed price",
        "CPFF": "cost plus fixed fee", "CPIF": "cost plus incentive fee",
        "FPIF": "fixed price incentive fee",
        // Configuration & change management
        "CM": "configuration management", "CCB": "configuration control board",
        "ECR": "engineering change request", "ECN": "engineering change notice",
        "ECP": "engineering change proposal", "CI": "configuration item",
        "CSCI": "computer software configuration item",
        "HWCI": "hardware configuration item",
        // Risk management
        "RMP": "risk management plan", "POA": "plan of action",
        // Space systems / astrodynamics
        "MOI": "moment of inertia", "COG": "center of gravity",
        "CG": "center of gravity", "COM": "center of mass",
        "GNC": "guidance navigation and control",
        "AOCS": "attitude and orbit control system",
        "ADCS": "attitude determination and control system",
        "ACS": "attitude control system", "IMU": "inertial measurement unit",
        "INS": "inertial navigation system",
        "GPS": "global positioning system",
        "GNSS": "global navigation satellite system",
        "TLE": "two-line element", "COE": "classical orbital elements",
        "LEO": "low Earth orbit", "MEO": "medium Earth orbit",
        "GEO": "geostationary orbit", "HEO": "highly elliptical orbit",
        "SSO": "sun-synchronous orbit", "GTO": "geostationary transfer orbit",
        "TLI": "trans-lunar injection", "TMI": "trans-Mars injection",
        "LOI": "lunar orbit insertion", "EDL": "entry descent and landing",
        "RAAN": "right ascension of the ascending node",
        "SMA": "semi-major axis", "ECC": "eccentricity",
        "INC": "inclination", "AOP": "argument of periapsis",
        "SRP": "solar radiation pressure",
        "LVLH": "local vertical local horizontal",
        "ECI": "Earth-centered inertial", "ECEF": "Earth-centered Earth-fixed",
        // Launch / propulsion
        "ISP": "specific impulse", "SRB": "solid rocket booster",
        "OMS": "orbital maneuvering system", "MES": "main engine start",
        "MECO": "main engine cutoff", "SECO": "second engine cutoff",
        "BECO": "booster engine cutoff", "LOX": "liquid oxygen",
        "LH2": "liquid hydrogen", "LCH4": "liquid methane",
        "MMH": "monomethylhydrazine", "NTO": "nitrogen tetroxide",
        "METHALOX": "methalox", "RP1": "R.P. one",
        // Spacecraft subsystems
        "CDH": "command and data handling", "EPS": "electrical power system",
        "TTC": "telemetry tracking and command",
        "TCS": "thermal control system", "MLI": "multi-layer insulation",
        "OBDH": "onboard data handling", "PDU": "power distribution unit",
        "RTG": "radioisotope thermoelectric generator",
        // Mission / operations
        "MCC": "mission control center", "MOC": "mission operations center",
        "SOC": "satellite operations center",
        "EVA": "extravehicular activity", "IVA": "intravehicular activity",
        "ECLSS": "environmental control and life support system",
        "ISRU": "in-situ resource utilization", "PDL": "payload data link",
        "TMTC": "telemetry and telecommand",
        "CCSDS": "consultative committee for space data systems",
        // Space environment / physics
        "SEE": "single event effect", "SEU": "single event upset",
        "TID": "total ionizing dose", "NIEL": "non-ionizing energy loss",
        "GCR": "galactic cosmic rays", "SPE": "solar particle event",
        "CME": "coronal mass ejection", "SAA": "South Atlantic anomaly",
        "BRDF": "bidirectional reflectance distribution function",
        // Comm / link budget
        "TWTA": "traveling wave tube amplifier",
        "SSPA": "solid state power amplifier", "LNA": "low noise amplifier",
        "BPF": "bandpass filter", "PLL": "phase locked loop",
        "QPSK": "quadrature phase shift keying",
        "BPSK": "binary phase shift keying",
        "OFDM": "orthogonal frequency division multiplexing",
        "FDMA": "frequency division multiple access",
        "TDMA": "time division multiple access",
        "CDMA": "code division multiple access",
    ]
}
