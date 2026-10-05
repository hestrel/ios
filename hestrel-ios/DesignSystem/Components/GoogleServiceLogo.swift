import SwiftUI

extension GoogleService {
    /// The service's full-color product logo.
    var logo: ImageResource {
        switch self {
        case .gmail: .gmailLogo
        case .calendar: .googleCalendarLogo
        case .drive: .googleDriveLogo
        }
    }
}

/// A Google product logo, scaled to fit a square.
struct GoogleServiceLogo: View {
    let service: GoogleService
    var size: CGFloat = 20

    var body: some View {
        Image(service.logo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
