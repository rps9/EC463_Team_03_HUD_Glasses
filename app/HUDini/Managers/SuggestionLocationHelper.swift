import Combine
import CoreLocation
import Foundation

@MainActor
final class SuggestionLocationHelper: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isLocating = false
    @Published var lastErrorMessage: String?
    /// Set after a successful one-shot reverse geocode.
    @Published private(set) var lastResolvedDisplay: String?
    @Published private(set) var lastResolvedLatitude: Double?
    @Published private(set) var lastResolvedLongitude: Double?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUseAccess() {
        manager.requestWhenInUseAuthorization()
    }

    /// Single fix (not continuous updates). Updates `authorizationStatus` when the user responds to the prompt.
    func detectCurrentLocation() {
        lastErrorMessage = nil
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            requestWhenInUseAccess()
            return
        }
        isLocating = true
        manager.requestLocation()
    }
}

extension SuggestionLocationHelper: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.isLocating = false
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                Task { @MainActor in
                    if let error {
                        self.lastErrorMessage = error.localizedDescription
                        return
                    }
                    guard let placemark = placemarks?.first else {
                        self.lastErrorMessage = "Could not resolve address."
                        return
                    }
                    let parts = [
                        placemark.locality,
                        placemark.administrativeArea,
                        placemark.country
                    ].compactMap { $0 }
                    let line = parts.joined(separator: ", ")
                    self.lastResolvedDisplay = line
                    self.lastResolvedLatitude = location.coordinate.latitude
                    self.lastResolvedLongitude = location.coordinate.longitude
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isLocating = false
            self.lastErrorMessage = error.localizedDescription
        }
    }
}
