//! GTK 3 and GDK declarations used by the Linux backend and its checks:
//! X keysyms, synthetic pointer events and the widget calls the checks make.
//! Values and layouts match the GTK 3 headers; key codes are X11 keysyms.

pub const GDK_KEY_Alt_L = 0xffe9;
pub const GDK_KEY_Alt_R = 0xffea;
pub const GDK_KEY_AudioLowerVolume = 0x1008ff11;
pub const GDK_KEY_AudioMute = 0x1008ff12;
pub const GDK_KEY_AudioNext = 0x1008ff17;
pub const GDK_KEY_AudioPause = 0x1008ff31;
pub const GDK_KEY_AudioPlay = 0x1008ff14;
pub const GDK_KEY_AudioPrev = 0x1008ff16;
pub const GDK_KEY_AudioRaiseVolume = 0x1008ff13;
pub const GDK_KEY_AudioStop = 0x1008ff15;
pub const GDK_KEY_Back = 0x1008ff26;
pub const GDK_KEY_BackSpace = 0xff08;
pub const GDK_KEY_Caps_Lock = 0xffe5;
pub const GDK_KEY_Control_L = 0xffe3;
pub const GDK_KEY_Control_R = 0xffe4;
pub const GDK_KEY_Delete = 0xffff;
pub const GDK_KEY_Down = 0xff54;
pub const GDK_KEY_End = 0xff57;
pub const GDK_KEY_Escape = 0xff1b;
pub const GDK_KEY_F1 = 0xffbe;
pub const GDK_KEY_F24 = 0xffd5;
pub const GDK_KEY_Favorites = 0x1008ff30;
pub const GDK_KEY_Forward = 0x1008ff27;
pub const GDK_KEY_Home = 0xff50;
pub const GDK_KEY_HomePage = 0x1008ff18;
pub const GDK_KEY_ISO_Left_Tab = 0xfe20;
pub const GDK_KEY_Insert = 0xff63;
pub const GDK_KEY_KP_0 = 0xffb0;
pub const GDK_KEY_KP_9 = 0xffb9;
pub const GDK_KEY_KP_Add = 0xffab;
pub const GDK_KEY_KP_Decimal = 0xffae;
pub const GDK_KEY_KP_Delete = 0xff9f;
pub const GDK_KEY_KP_Divide = 0xffaf;
pub const GDK_KEY_KP_Down = 0xff99;
pub const GDK_KEY_KP_End = 0xff9c;
pub const GDK_KEY_KP_Enter = 0xff8d;
pub const GDK_KEY_KP_Home = 0xff95;
pub const GDK_KEY_KP_Insert = 0xff9e;
pub const GDK_KEY_KP_Left = 0xff96;
pub const GDK_KEY_KP_Multiply = 0xffaa;
pub const GDK_KEY_KP_Page_Down = 0xff9b;
pub const GDK_KEY_KP_Page_Up = 0xff9a;
pub const GDK_KEY_KP_Right = 0xff98;
pub const GDK_KEY_KP_Space = 0xff80;
pub const GDK_KEY_KP_Subtract = 0xffad;
pub const GDK_KEY_KP_Tab = 0xff89;
pub const GDK_KEY_KP_Up = 0xff97;
pub const GDK_KEY_Left = 0xff51;
pub const GDK_KEY_Menu = 0xff67;
pub const GDK_KEY_Meta_L = 0xffe7;
pub const GDK_KEY_Meta_R = 0xffe8;
pub const GDK_KEY_Num_Lock = 0xff7f;
pub const GDK_KEY_Page_Down = 0xff56;
pub const GDK_KEY_Page_Up = 0xff55;
pub const GDK_KEY_Pause = 0xff13;
pub const GDK_KEY_Print = 0xff61;
pub const GDK_KEY_Refresh = 0x1008ff29;
pub const GDK_KEY_Return = 0xff0d;
pub const GDK_KEY_Right = 0xff53;
pub const GDK_KEY_Scroll_Lock = 0xff14;
pub const GDK_KEY_Search = 0x1008ff1b;
pub const GDK_KEY_Shift_L = 0xffe1;
pub const GDK_KEY_Shift_R = 0xffe2;
pub const GDK_KEY_Stop = 0x1008ff28;
pub const GDK_KEY_Super_L = 0xffeb;
pub const GDK_KEY_Super_R = 0xffec;
pub const GDK_KEY_Tab = 0xff09;
pub const GDK_KEY_Up = 0xff52;
pub const GDK_KEY_space = 0x020;

pub const GDK_MOTION_NOTIFY: c_int = 3;
pub const GDK_BUTTON_PRESS: c_int = 4;
pub const GDK_BUTTON_RELEASE: c_int = 7;
pub const GDK_BUTTON1_MASK: c_uint = 1 << 8;

pub const GtkWidget = opaque {};
pub const GtkBin = opaque {};
pub const GdkWindow = opaque {};
pub const GdkDevice = opaque {};

pub const GdkEventButton = extern struct {
    type: c_int,
    window: ?*GdkWindow,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    axes: ?*f64,
    state: c_uint,
    button: c_uint,
    device: ?*GdkDevice,
    x_root: f64,
    y_root: f64,
};

pub const GdkEventMotion = extern struct {
    type: c_int,
    window: ?*GdkWindow,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    axes: ?*f64,
    state: c_uint,
    is_hint: i16,
    device: ?*GdkDevice,
    x_root: f64,
    y_root: f64,
};

pub extern fn gtk_bin_get_child(bin: ?*GtkBin) ?*GtkWidget;
pub extern fn gtk_widget_get_window(widget: ?*GtkWidget) ?*GdkWindow;
pub extern fn gtk_widget_grab_focus(widget: ?*GtkWidget) void;
pub extern fn gtk_widget_has_focus(widget: ?*GtkWidget) c_int;
pub extern fn g_object_ref(object: ?*anyopaque) ?*anyopaque;
pub extern fn g_object_unref(object: ?*anyopaque) void;
pub extern fn g_signal_emit_by_name(instance: ?*anyopaque, detailed_signal: [*:0]const u8, ...) void;
