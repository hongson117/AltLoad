#[derive(Debug, Clone)]
pub enum DeveloperDeviceType {
    Any,
    Ios,
    Tvos,
    Watchos,
}

impl DeveloperDeviceType {
    pub fn url_segment(&self) -> &'static str {
        match self {
            DeveloperDeviceType::Any => "",
            DeveloperDeviceType::Ios => "ios/",
            // Apple has no tvos/ path (HTTP 404); tvOS uses ios/ plus DTDK_Platform (see AltSign).
            DeveloperDeviceType::Tvos => "ios/",
            DeveloperDeviceType::Watchos => "watchos/",
        }
    }
}

pub fn dev_url(endpoint: &str, device_type: impl Into<Option<DeveloperDeviceType>>) -> String {
    format!(
        "https://developerservices2.apple.com/services/QH65B2/{}{}.action?clientId=XABBG36SBA",
        device_type
            .into()
            .unwrap_or(DeveloperDeviceType::Ios)
            .url_segment(),
        endpoint,
    )
}

/// AltSign-style platform params for addDevice / downloadTeamProvisioningProfile.
pub fn add_platform_params(body: &mut plist::Dictionary, device_type: &Option<DeveloperDeviceType>) {
    if let Some(DeveloperDeviceType::Tvos) = device_type {
        body.insert("DTDK_Platform".into(), "tvos".into());
        body.insert("subPlatform".into(), "tvOS".into());
    }
}
