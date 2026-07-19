import Foundation
import CoreLocation

struct AirportRef: Codable, Hashable, Identifiable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lon: Double
    let tz: String
    var id: String { iata }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct AirlineRef: Codable, Hashable, Identifiable {
    let iata: String
    let icao: String
    let name: String
    let callsign: String
    let country: String
    var id: String { iata }
}
