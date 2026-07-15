import MWDATDisplay

enum IdentityDisplayCard: Sendable, Equatable {
  case identifying
  case name(String)
  case enriched(name: String, role: String, company: String)
  case notIdentified
}

enum IdentifyPersonDisplayCard {
  static func make(_ card: IdentityDisplayCard) -> FlexBox {
    let lines: (String, String?) = switch card {
    case .identifying: ("Identifying…", nil)
    case .name(let name): (name, nil)
    case .enriched(let name, let role, let company): (name, "\(role) at \(company)")
    case .notIdentified: ("Not identified", nil)
    }
    return FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
      MWDATDisplay.Text(lines.0, style: .heading)
      if let detail = lines.1 {
        MWDATDisplay.Text(detail, style: .body)
      }
    }
    .padding(24)
    .background(.card)
  }
}
