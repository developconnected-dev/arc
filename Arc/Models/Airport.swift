import Foundation
import SwiftData

@Model
final class Airport {
    @Attribute(.unique) var iata: String = ""
    var name: String = ""
    var city: String = ""
    var country: String = ""
    var lat: Double = 0
    var lon: Double = 0
    var timezone: String = ""

    init(iata: String, name: String, city: String, country: String, lat: Double, lon: Double, timezone: String = "") {
        self.iata = iata
        self.name = name
        self.city = city
        self.country = country
        self.lat = lat
        self.lon = lon
        self.timezone = timezone
    }
}
