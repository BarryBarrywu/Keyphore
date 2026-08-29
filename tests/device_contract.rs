use nuphy_codex::device::{Bus, DeviceDescriptor, select_supported_device};

fn air65() -> DeviceDescriptor {
    DeviceDescriptor {
        path: "air65-control".into(),
        vendor_id: 0x19f5,
        product_id: 0x102b,
        product: "Air65 V3".into(),
        bus: Bus::Usb,
        interface_number: 3,
        usage_page: 0x0001,
        usage: 0x0000,
    }
}

#[test]
fn discovers_only_the_verified_air65_v3_usb_control_interface() {
    let mut keyboard_interface = air65();
    keyboard_interface.path = "ordinary-keyboard".into();
    keyboard_interface.usage = 0x0006;
    let devices = vec![keyboard_interface, air65()];

    let supported = select_supported_device(&devices).unwrap();

    assert_eq!(supported.path, "air65-control");
    assert_eq!(supported.product, "Air65 V3");
}

#[test]
fn rejects_unknown_models_transports_and_interfaces() {
    let mut unknown_model = air65();
    unknown_model.product_id = 0x1028;
    unknown_model.product = "NuPhy Air75 V3".into();
    assert!(select_supported_device(&[unknown_model]).is_err());

    let mut bluetooth = air65();
    bluetooth.bus = Bus::Bluetooth;
    assert!(select_supported_device(&[bluetooth]).is_err());

    let mut wrong_interface = air65();
    wrong_interface.usage = 0x0006;
    assert!(select_supported_device(&[wrong_interface]).is_err());
}

#[test]
fn rejects_ambiguous_supported_interfaces() {
    assert!(select_supported_device(&[air65(), air65()]).is_err());
}
