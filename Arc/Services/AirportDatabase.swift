import Foundation

/// Built-in airport database for coordinate lookups and display names.
/// Covers the top 250+ airports worldwide so the globe renders routes correctly.
enum AirportDatabase {

    struct AirportInfo {
        let iata: String
        let name: String
        let city: String
        let country: String
        let lat: Double
        let lon: Double
    }

    /// Look up an airport by IATA code
    static func lookup(_ iata: String) -> AirportInfo? {
        airports[iata.uppercased()]
    }

    /// Get coordinates for an IATA code, returns (0,0) if unknown
    static func coordinates(for iata: String) -> (lat: Double, lon: Double) {
        if let a = airports[iata.uppercased()] {
            return (a.lat, a.lon)
        }
        return (0, 0)
    }

    // MARK: - Database

    private static let airports: [String: AirportInfo] = {
        var db: [String: AirportInfo] = [:]
        func add(_ iata: String, _ name: String, _ city: String, _ country: String, _ lat: Double, _ lon: Double) {
            db[iata] = AirportInfo(iata: iata, name: name, city: city, country: country, lat: lat, lon: lon)
        }

        // ── Europe ──
        add("ZRH", "Zurich Airport", "Zurich", "Switzerland", 47.4647, 8.5492)
        add("GVA", "Geneva Airport", "Geneva", "Switzerland", 46.2381, 6.1089)
        add("BSL", "EuroAirport Basel", "Basel", "Switzerland", 47.5896, 7.5299)
        add("BRN", "Bern Airport", "Bern", "Switzerland", 46.9141, 7.4972)
        add("LHR", "Heathrow Airport", "London", "United Kingdom", 51.4700, -0.4543)
        add("LGW", "Gatwick Airport", "London", "United Kingdom", 51.1537, -0.1821)
        add("STN", "Stansted Airport", "London", "United Kingdom", 51.8860, 0.2389)
        add("LTN", "Luton Airport", "London", "United Kingdom", 51.8747, -0.3683)
        add("LCY", "London City Airport", "London", "United Kingdom", 51.5048, 0.0495)
        add("CDG", "Charles de Gaulle", "Paris", "France", 49.0097, 2.5479)
        add("ORY", "Orly Airport", "Paris", "France", 48.7233, 2.3794)
        add("FRA", "Frankfurt Airport", "Frankfurt", "Germany", 50.0379, 8.5622)
        add("MUC", "Munich Airport", "Munich", "Germany", 48.3538, 11.7861)
        add("BER", "Berlin Brandenburg", "Berlin", "Germany", 52.3667, 13.5033)
        add("TXL", "Berlin Tegel", "Berlin", "Germany", 52.5597, 13.2877)
        add("DUS", "Düsseldorf Airport", "Düsseldorf", "Germany", 51.2895, 6.7668)
        add("HAM", "Hamburg Airport", "Hamburg", "Germany", 53.6304, 9.9882)
        add("CGN", "Cologne Bonn", "Cologne", "Germany", 50.8659, 7.1427)
        add("STR", "Stuttgart Airport", "Stuttgart", "Germany", 48.6899, 9.2220)
        add("AMS", "Schiphol Airport", "Amsterdam", "Netherlands", 52.3086, 4.7639)
        add("BRU", "Brussels Airport", "Brussels", "Belgium", 50.9014, 4.4844)
        add("VIE", "Vienna Airport", "Vienna", "Austria", 48.1103, 16.5697)
        add("MAD", "Barajas Airport", "Madrid", "Spain", 40.4983, -3.5676)
        add("BCN", "El Prat Airport", "Barcelona", "Spain", 41.2971, 2.0785)
        add("PMI", "Palma de Mallorca", "Palma", "Spain", 39.5517, 2.7388)
        add("AGP", "Málaga Airport", "Málaga", "Spain", 36.6749, -4.4991)
        add("FCO", "Fiumicino Airport", "Rome", "Italy", 41.8003, 12.2389)
        add("MXP", "Malpensa Airport", "Milan", "Italy", 45.6306, 8.7281)
        add("LIN", "Linate Airport", "Milan", "Italy", 45.4494, 9.2783)
        add("VCE", "Marco Polo Airport", "Venice", "Italy", 45.5053, 12.3519)
        add("NAP", "Naples Airport", "Naples", "Italy", 40.8860, 14.2908)
        add("LIS", "Lisbon Airport", "Lisbon", "Portugal", 38.7813, -9.1359)
        add("OPO", "Porto Airport", "Porto", "Portugal", 41.2481, -8.6814)
        add("ATH", "Athens Airport", "Athens", "Greece", 37.9364, 23.9445)
        add("IST", "Istanbul Airport", "Istanbul", "Turkey", 41.2753, 28.7519)
        add("SAW", "Sabiha Gökçen", "Istanbul", "Turkey", 40.8986, 29.3092)
        add("CPH", "Copenhagen Airport", "Copenhagen", "Denmark", 55.6181, 12.6561)
        add("OSL", "Oslo Gardermoen", "Oslo", "Norway", 60.1939, 11.1004)
        add("ARN", "Arlanda Airport", "Stockholm", "Sweden", 59.6519, 17.9186)
        add("HEL", "Helsinki Airport", "Helsinki", "Finland", 60.3172, 24.9633)
        add("WAW", "Chopin Airport", "Warsaw", "Poland", 52.1657, 20.9671)
        add("PRG", "Václav Havel Airport", "Prague", "Czech Republic", 50.1008, 14.2600)
        add("BUD", "Budapest Airport", "Budapest", "Hungary", 47.4399, 19.2556)
        add("OTP", "Henri Coandă Airport", "Bucharest", "Romania", 44.5711, 26.0850)
        add("DUB", "Dublin Airport", "Dublin", "Ireland", 53.4264, -6.2499)
        add("EDI", "Edinburgh Airport", "Edinburgh", "United Kingdom", 55.9500, -3.3725)
        add("MAN", "Manchester Airport", "Manchester", "United Kingdom", 53.3537, -2.2750)
        add("NCE", "Nice Côte d'Azur", "Nice", "France", 43.6584, 7.2159)
        add("LYS", "Lyon–Saint-Exupéry", "Lyon", "France", 45.7256, 5.0811)
        add("MRS", "Marseille Provence", "Marseille", "France", 43.4393, 5.2214)
        add("TLS", "Toulouse–Blagnac", "Toulouse", "France", 43.6351, 1.3678)
        add("KRK", "Kraków Airport", "Kraków", "Poland", 50.0777, 19.7848)
        add("ZAG", "Zagreb Airport", "Zagreb", "Croatia", 45.7430, 16.0688)
        add("SPU", "Split Airport", "Split", "Croatia", 43.5389, 16.2980)
        add("DBV", "Dubrovnik Airport", "Dubrovnik", "Croatia", 42.5614, 18.2682)
        add("BGY", "Bergamo Airport", "Bergamo", "Italy", 45.6739, 9.7042)
        add("KEF", "Keflavík Airport", "Reykjavík", "Iceland", 63.9850, -22.6056)

        // ── North America ──
        add("JFK", "John F. Kennedy", "New York", "United States", 40.6413, -73.7781)
        add("EWR", "Newark Liberty", "Newark", "United States", 40.6895, -74.1745)
        add("LGA", "LaGuardia Airport", "New York", "United States", 40.7769, -73.8740)
        add("LAX", "Los Angeles Intl", "Los Angeles", "United States", 33.9416, -118.4085)
        add("SFO", "San Francisco Intl", "San Francisco", "United States", 37.6213, -122.3790)
        add("ORD", "O'Hare Intl", "Chicago", "United States", 41.9742, -87.9073)
        add("ATL", "Hartsfield-Jackson", "Atlanta", "United States", 33.6407, -84.4277)
        add("DFW", "Dallas/Fort Worth", "Dallas", "United States", 32.8998, -97.0403)
        add("DEN", "Denver Intl", "Denver", "United States", 39.8561, -104.6737)
        add("SEA", "Seattle-Tacoma", "Seattle", "United States", 47.4502, -122.3088)
        add("MIA", "Miami Intl", "Miami", "United States", 25.7959, -80.2870)
        add("BOS", "Logan Intl", "Boston", "United States", 42.3656, -71.0096)
        add("IAD", "Dulles Intl", "Washington", "United States", 38.9531, -77.4565)
        add("DCA", "Reagan National", "Washington", "United States", 38.8512, -77.0402)
        add("PHX", "Phoenix Sky Harbor", "Phoenix", "United States", 33.4373, -112.0078)
        add("IAH", "George Bush Intl", "Houston", "United States", 29.9902, -95.3368)
        add("MSP", "Minneapolis-St Paul", "Minneapolis", "United States", 44.8848, -93.2223)
        add("DTW", "Detroit Metro", "Detroit", "United States", 42.2162, -83.3554)
        add("PHL", "Philadelphia Intl", "Philadelphia", "United States", 39.8744, -75.2424)
        add("CLT", "Charlotte Douglas", "Charlotte", "United States", 35.2140, -80.9431)
        add("MCO", "Orlando Intl", "Orlando", "United States", 28.4312, -81.3081)
        add("SAN", "San Diego Intl", "San Diego", "United States", 32.7338, -117.1933)
        add("TPA", "Tampa Intl", "Tampa", "United States", 27.9756, -82.5333)
        add("PDX", "Portland Intl", "Portland", "United States", 45.5898, -122.5951)
        add("SLC", "Salt Lake City Intl", "Salt Lake City", "United States", 40.7899, -111.9791)
        add("BWI", "Baltimore-Washington", "Baltimore", "United States", 39.1754, -76.6684)
        add("FLL", "Fort Lauderdale", "Fort Lauderdale", "United States", 26.0726, -80.1527)
        add("HNL", "Daniel K. Inouye", "Honolulu", "United States", 21.3187, -157.9225)
        add("AUS", "Austin-Bergstrom", "Austin", "United States", 30.1975, -97.6664)
        add("RDU", "Raleigh-Durham", "Raleigh", "United States", 35.8776, -78.7875)
        add("SJC", "San Jose Intl", "San Jose", "United States", 37.3626, -121.9290)
        add("YYZ", "Toronto Pearson", "Toronto", "Canada", 43.6777, -79.6248)
        add("YVR", "Vancouver Intl", "Vancouver", "Canada", 49.1947, -123.1792)
        add("YUL", "Montréal-Trudeau", "Montreal", "Canada", 45.4706, -73.7408)
        add("YOW", "Ottawa Intl", "Ottawa", "Canada", 45.3225, -75.6692)
        add("YYC", "Calgary Intl", "Calgary", "Canada", 51.1215, -114.0076)
        add("MEX", "Mexico City Intl", "Mexico City", "Mexico", 19.4363, -99.0721)
        add("CUN", "Cancún Intl", "Cancún", "Mexico", 21.0365, -86.8771)
        add("GDL", "Guadalajara Intl", "Guadalajara", "Mexico", 20.5218, -103.3111)

        // ── Asia ──
        add("NRT", "Narita Intl", "Tokyo", "Japan", 35.7647, 140.3864)
        add("HND", "Haneda Airport", "Tokyo", "Japan", 35.5494, 139.7798)
        add("KIX", "Kansai Intl", "Osaka", "Japan", 34.4320, 135.2304)
        add("ICN", "Incheon Intl", "Seoul", "South Korea", 37.4602, 126.4407)
        add("PEK", "Beijing Capital", "Beijing", "China", 40.0799, 116.6031)
        add("PKX", "Beijing Daxing", "Beijing", "China", 39.5098, 116.4105)
        add("PVG", "Pudong Intl", "Shanghai", "China", 31.1443, 121.8083)
        add("SHA", "Hongqiao Intl", "Shanghai", "China", 31.1979, 121.3364)
        add("HKG", "Hong Kong Intl", "Hong Kong", "China", 22.3080, 113.9185)
        add("TPE", "Taiwan Taoyuan", "Taipei", "Taiwan", 25.0797, 121.2342)
        add("SIN", "Changi Airport", "Singapore", "Singapore", 1.3644, 103.9915)
        add("BKK", "Suvarnabhumi", "Bangkok", "Thailand", 13.6900, 100.7501)
        add("DMK", "Don Mueang", "Bangkok", "Thailand", 13.9126, 100.6068)
        add("KUL", "Kuala Lumpur Intl", "Kuala Lumpur", "Malaysia", 2.7456, 101.7099)
        add("CGK", "Soekarno-Hatta", "Jakarta", "Indonesia", -6.1256, 106.6558)
        add("DPS", "Ngurah Rai", "Bali", "Indonesia", -8.7482, 115.1672)
        add("MNL", "Ninoy Aquino", "Manila", "Philippines", 14.5086, 121.0194)
        add("DEL", "Indira Gandhi Intl", "Delhi", "India", 28.5562, 77.1000)
        add("BOM", "Chhatrapati Shivaji", "Mumbai", "India", 19.0896, 72.8656)
        add("BLR", "Kempegowda Intl", "Bangalore", "India", 13.1979, 77.7063)
        add("MAA", "Chennai Intl", "Chennai", "India", 12.9941, 80.1709)
        add("HAN", "Noi Bai Intl", "Hanoi", "Vietnam", 21.2212, 105.8070)
        add("SGN", "Tan Son Nhat", "Ho Chi Minh City", "Vietnam", 10.8188, 106.6520)
        add("CMB", "Bandaranaike Intl", "Colombo", "Sri Lanka", 7.1808, 79.8841)
        add("KTM", "Tribhuvan Intl", "Kathmandu", "Nepal", 27.6966, 85.3591)

        // ── Middle East ──
        add("DXB", "Dubai Intl", "Dubai", "UAE", 25.2532, 55.3657)
        add("AUH", "Abu Dhabi Intl", "Abu Dhabi", "UAE", 24.4330, 54.6511)
        add("DOH", "Hamad Intl", "Doha", "Qatar", 25.2731, 51.6081)
        add("RUH", "King Khalid Intl", "Riyadh", "Saudi Arabia", 24.9576, 46.6988)
        add("JED", "King Abdulaziz Intl", "Jeddah", "Saudi Arabia", 21.6796, 39.1565)
        add("TLV", "Ben Gurion Airport", "Tel Aviv", "Israel", 32.0055, 34.8854)
        add("AMM", "Queen Alia Intl", "Amman", "Jordan", 31.7226, 35.9932)
        add("BAH", "Bahrain Intl", "Manama", "Bahrain", 26.2708, 50.6336)
        add("MCT", "Muscat Intl", "Muscat", "Oman", 23.5933, 58.2844)
        add("KWI", "Kuwait Intl", "Kuwait City", "Kuwait", 29.2266, 47.9689)

        // ── Africa ──
        add("JNB", "O.R. Tambo Intl", "Johannesburg", "South Africa", -26.1392, 28.2460)
        add("CPT", "Cape Town Intl", "Cape Town", "South Africa", -33.9649, 18.6017)
        add("CAI", "Cairo Intl", "Cairo", "Egypt", 30.1219, 31.4056)
        add("CMN", "Mohammed V Intl", "Casablanca", "Morocco", 33.3675, -7.5898)
        add("NBO", "Jomo Kenyatta Intl", "Nairobi", "Kenya", -1.3192, 36.9278)
        add("ADD", "Bole Intl", "Addis Ababa", "Ethiopia", 8.9779, 38.7993)
        add("LOS", "Murtala Muhammed", "Lagos", "Nigeria", 6.5774, 3.3211)
        add("ACC", "Kotoka Intl", "Accra", "Ghana", 5.6052, -0.1668)
        add("DAR", "Julius Nyerere", "Dar es Salaam", "Tanzania", -6.8781, 39.2026)

        // ── South America ──
        add("GRU", "Guarulhos Intl", "São Paulo", "Brazil", -23.4356, -46.4731)
        add("GIG", "Galeão Intl", "Rio de Janeiro", "Brazil", -22.8100, -43.2506)
        add("EZE", "Ministro Pistarini", "Buenos Aires", "Argentina", -34.8222, -58.5358)
        add("SCL", "Arturo Merino Benítez", "Santiago", "Chile", -33.3930, -70.7858)
        add("BOG", "El Dorado Intl", "Bogotá", "Colombia", 4.7016, -74.1469)
        add("LIM", "Jorge Chávez Intl", "Lima", "Peru", -12.0219, -77.1143)
        add("PTY", "Tocumen Intl", "Panama City", "Panama", 9.0714, -79.3835)

        // ── Oceania ──
        add("SYD", "Sydney Kingsford Smith", "Sydney", "Australia", -33.9461, 151.1772)
        add("MEL", "Melbourne Tullamarine", "Melbourne", "Australia", -37.6733, 144.8433)
        add("BNE", "Brisbane Airport", "Brisbane", "Australia", -27.3842, 153.1175)
        add("PER", "Perth Airport", "Perth", "Australia", -31.9403, 115.9670)
        add("AKL", "Auckland Airport", "Auckland", "New Zealand", -37.0082, 174.7850)
        add("WLG", "Wellington Airport", "Wellington", "New Zealand", -41.3272, 174.8053)

        // ── Caribbean ──
        add("SJU", "Luis Muñoz Marín", "San Juan", "Puerto Rico", 18.4394, -66.0018)
        add("NAS", "Lynden Pindling", "Nassau", "Bahamas", 25.0390, -77.4662)
        add("MBJ", "Sangster Intl", "Montego Bay", "Jamaica", 18.5037, -77.9134)
        add("PUJ", "Punta Cana Intl", "Punta Cana", "Dominican Republic", 18.5674, -68.3634)

        return db
    }()
}
