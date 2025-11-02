
pub fn extract_rating(xmp: &str) -> Option<String> {
    // XMP rating is typically in xmp:Rating tag
    // Format: <xmp:Rating>5</xmp:Rating>
    if let Some(start) = xmp.find("<xmp:Rating>") {
        let start_idx = start + "<xmp:Rating>".len();
        if let Some(end) = xmp[start_idx..].find("</xmp:Rating>") {
            return Some(xmp[start_idx..start_idx + end].trim().to_string());
        }
    }
    
    // Alternative format with attribute
    // Format: xmp:Rating="5"
    if let Some(start) = xmp.find("xmp:Rating=\"") {
        let start_idx = start + "xmp:Rating=\"".len();
        if let Some(end) = xmp[start_idx..].find("\"") {
            return Some(xmp[start_idx..start_idx + end].trim().to_string());
        }
    }
    
    None
}

pub fn extract_color_label(xmp: &str) -> Option<String> {
    // XMP color label is typically in xmp:Label tag
    // Format: <xmp:Label>Red</xmp:Label>
    if let Some(start) = xmp.find("<xmp:Label>") {
        let start_idx = start + "<xmp:Label>".len();
        if let Some(end) = xmp[start_idx..].find("</xmp:Label>") {
            return Some(xmp[start_idx..start_idx + end].trim().to_string());
        }
    }
    
    // Alternative format with attribute
    // Format: xmp:Label="Red"
    if let Some(start) = xmp.find("xmp:Label=\"") {
        let start_idx = start + "xmp:Label=\"".len();
        if let Some(end) = xmp[start_idx..].find("\"") {
            return Some(xmp[start_idx..start_idx + end].trim().to_string());
        }
    }
    
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_extract_rating_tag() {
        let xmp = r#"<xmp:Rating>5</xmp:Rating>"#;
        assert_eq!(extract_rating(xmp), Some("5".to_string()));
    }
    
    #[test]
    fn test_extract_rating_attribute() {
        let xmp = r#"xmp:Rating="3""#;
        assert_eq!(extract_rating(xmp), Some("3".to_string()));
    }
    
    #[test]
    fn test_extract_color_label_tag() {
        let xmp = r#"<xmp:Label>Red</xmp:Label>"#;
        assert_eq!(extract_color_label(xmp), Some("Red".to_string()));
    }
    
    #[test]
    fn test_extract_color_label_attribute() {
        let xmp = r#"xmp:Label="Blue""#;
        assert_eq!(extract_color_label(xmp), Some("Blue".to_string()));
    }
}