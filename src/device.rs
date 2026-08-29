use anyhow::{Result, bail};

pub const NUPHY_VENDOR_ID: u16 = 0x19f5;
pub const AIR65_V3_PRODUCT_ID: u16 = 0x102b;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Bus {
    Usb,
    Bluetooth,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceDescriptor {
    pub path: String,
    pub vendor_id: u16,
    pub product_id: u16,
    pub product: String,
    pub bus: Bus,
    pub interface_number: i32,
    pub usage_page: u16,
    pub usage: u16,
}

pub fn select_supported_device(devices: &[DeviceDescriptor]) -> Result<&DeviceDescriptor> {
    let matching_model: Vec<_> = devices
        .iter()
        .filter(|device| {
            device.vendor_id == NUPHY_VENDOR_ID && device.product_id == AIR65_V3_PRODUCT_ID
        })
        .collect();

    if matching_model.is_empty() {
        bail!("supported NuPhy Air65 V3 (USB 19f5:102b) not found");
    }

    let supported: Vec<_> = matching_model
        .iter()
        .copied()
        .filter(|device| {
            device.bus == Bus::Usb
                && device.product == "Air65 V3"
                && device.interface_number == 3
                && device.usage_page == 0x0001
                && device.usage == 0x0000
        })
        .collect();

    match supported.as_slice() {
        [device] => Ok(device),
        [] => {
            bail!("Air65 V3 was found, but its transport or HID control interface is unsupported")
        }
        _ => bail!("multiple Air65 V3 control interfaces matched; refusing an ambiguous write"),
    }
}
