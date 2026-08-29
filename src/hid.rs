use std::time::Duration;

use anyhow::{Context, Result, bail};
use hidapi::{BusType, DeviceInfo, HidApi, HidDevice};

use crate::device::{Bus, DeviceDescriptor, select_supported_device};
use crate::diagnostic::ReportTransport;
use crate::protocol::{REPORT_LEN, Report, parse_report};

pub struct DiscoveredKeyboard {
    pub descriptor: DeviceDescriptor,
    pub transport: HidReportTransport,
}

pub fn discover_air65_v3() -> Result<DiscoveredKeyboard> {
    let api = HidApi::new().context("failed to enumerate macOS HID devices")?;
    let descriptors: Vec<_> = api.device_list().map(descriptor).collect();
    let selected = select_supported_device(&descriptors)?.clone();
    let info = api
        .device_list()
        .find(|info| info.path().to_string_lossy() == selected.path)
        .context("selected Air65 V3 interface disappeared during discovery")?;
    let device = info
        .open_device(&api)
        .context("failed to open the Air65 V3 USB control interface")?;
    let mut transport = HidReportTransport { device };
    transport.drain_stale_reports()?;
    Ok(DiscoveredKeyboard {
        descriptor: selected,
        transport,
    })
}

pub struct HidReportTransport {
    device: HidDevice,
}

impl HidReportTransport {
    fn drain_stale_reports(&mut self) -> Result<()> {
        let mut buffer = [0u8; REPORT_LEN + 1];
        loop {
            let count = self
                .device
                .read_timeout(&mut buffer, 0)
                .context("failed to drain stale HID input reports")?;
            if count == 0 {
                return Ok(());
            }
        }
    }
}

impl ReportTransport for HidReportTransport {
    fn send(&mut self, report: &Report) -> Result<()> {
        let mut wire_report = [0u8; REPORT_LEN + 1];
        wire_report[1..].copy_from_slice(report);
        self.device
            .send_output_report(&wire_report)
            .context("failed to write a 64-byte NuPhyIO output report")
    }

    fn receive(&mut self, timeout: Duration) -> Result<Option<Report>> {
        let timeout_ms = timeout.as_millis().clamp(1, i32::MAX as u128) as i32;
        let mut buffer = [0u8; REPORT_LEN + 1];
        let count = self
            .device
            .read_timeout(&mut buffer, timeout_ms)
            .context("failed to read a NuPhyIO input report")?;
        match count {
            0 => Ok(None),
            REPORT_LEN => Ok(Some(parse_report(&buffer[..REPORT_LEN])?)),
            length if length == REPORT_LEN + 1 => Ok(Some(parse_report(&buffer[1..])?)),
            length => bail!("unexpected HID input report length: {length} bytes"),
        }
    }
}

fn descriptor(info: &DeviceInfo) -> DeviceDescriptor {
    DeviceDescriptor {
        path: info.path().to_string_lossy().into_owned(),
        vendor_id: info.vendor_id(),
        product_id: info.product_id(),
        product: info.product_string().unwrap_or_default().to_owned(),
        bus: match info.bus_type() {
            BusType::Usb => Bus::Usb,
            BusType::Bluetooth => Bus::Bluetooth,
            _ => Bus::Other,
        },
        interface_number: info.interface_number(),
        usage_page: info.usage_page(),
        usage: info.usage(),
    }
}
