// Pads through GameController.framework: GCController's controllers with
// an extended gamepad profile, which Xbox, PlayStation, Switch Pro and MFi
// controllers have. The framework finds controllers on the main run loop,
// which a running app turns. Manual reference counting (-fno-objc-arc).
#import <GameController/GameController.h>
#include <string.h>

// The order of the standard layout's buttons (gamepad.zig `Button`).
enum {
    zgc_south,
    zgc_east,
    zgc_west,
    zgc_north,
    zgc_left_shoulder,
    zgc_right_shoulder,
    zgc_left_trigger,
    zgc_right_trigger,
    zgc_back,
    zgc_start,
    zgc_left_stick_button,
    zgc_right_stick_button,
    zgc_up,
    zgc_down,
    zgc_left,
    zgc_right,
    zgc_guide,
    zgc_button_count,
};

static float zgc_value(GCControllerButtonInput *input) {
    return input != nil ? input.value : 0;
}

static float zgc_axis(GCControllerAxisInput *input) {
    return input != nil ? input.value : 0;
}

// The connected controllers with an extended gamepad, unretained, written
// to `out`; the count is how many there are, which may exceed `capacity`.
int zgc_controllers(void **out, int capacity) {
    int count = 0;
    @autoreleasepool {
        for (GCController *controller in [GCController controllers]) {
            // A remote or a micro gamepad.
            if (controller.extendedGamepad == nil) continue;
            if (count < capacity) out[count] = controller;
            count++;
        }
    }
    return count;
}

void *zgc_retain(void *controller) {
    return [(GCController *)controller retain];
}

void zgc_release(void *controller) {
    [(GCController *)controller release];
}

// The controller's vendor name, cut to fit `capacity` bytes.
int zgc_name(void *controller, char *buffer, int capacity) {
    int length = 0;
    @autoreleasepool {
        const char *text = [((GCController *)controller).vendorName UTF8String];
        if (text != NULL) {
            length = (int)strlen(text);
            if (length > capacity) length = capacity;
            memcpy(buffer, text, (size_t)length);
        }
    }
    return length;
}

static int zgc_present(GCController *controller) {
    for (GCController *other in [GCController controllers]) {
        if (other == controller) return 1;
    }
    return 0;
}

// Reads the controller's buttons and axes in the standard layout. 0 when
// it is gone: no longer among the controllers, unless `check_present` is
// 0, as for a controller tests make.
int zgc_read(void *pointer, int check_present, float *buttons, float *axes) {
    GCController *controller = pointer;
    int ok = 1;
    @autoreleasepool {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if ((check_present && !zgc_present(controller)) || pad == nil) {
            ok = 0;
        } else {
            buttons[zgc_south] = zgc_value(pad.buttonA);
            buttons[zgc_east] = zgc_value(pad.buttonB);
            buttons[zgc_west] = zgc_value(pad.buttonX);
            buttons[zgc_north] = zgc_value(pad.buttonY);
            buttons[zgc_left_shoulder] = zgc_value(pad.leftShoulder);
            buttons[zgc_right_shoulder] = zgc_value(pad.rightShoulder);
            buttons[zgc_left_trigger] = zgc_value(pad.leftTrigger);
            buttons[zgc_right_trigger] = zgc_value(pad.rightTrigger);
            // Older systems have no Options, Menu or Home button.
            if ([pad respondsToSelector:@selector(buttonOptions)]) buttons[zgc_back] = zgc_value(pad.buttonOptions);
            if ([pad respondsToSelector:@selector(buttonMenu)]) buttons[zgc_start] = zgc_value(pad.buttonMenu);
            if ([pad respondsToSelector:@selector(buttonHome)]) buttons[zgc_guide] = zgc_value(pad.buttonHome);
            if ([pad respondsToSelector:@selector(leftThumbstickButton)]) buttons[zgc_left_stick_button] = zgc_value(pad.leftThumbstickButton);
            if ([pad respondsToSelector:@selector(rightThumbstickButton)]) buttons[zgc_right_stick_button] = zgc_value(pad.rightThumbstickButton);
            GCControllerDirectionPad *dpad = pad.dpad;
            if (dpad != nil) {
                buttons[zgc_up] = zgc_value(dpad.up);
                buttons[zgc_down] = zgc_value(dpad.down);
                buttons[zgc_left] = zgc_value(dpad.left);
                buttons[zgc_right] = zgc_value(dpad.right);
            }
            // GameController's y axes go up.
            if (pad.leftThumbstick != nil) {
                axes[0] = zgc_axis(pad.leftThumbstick.xAxis);
                axes[1] = -zgc_axis(pad.leftThumbstick.yAxis);
            }
            if (pad.rightThumbstick != nil) {
                axes[2] = zgc_axis(pad.rightThumbstick.xAxis);
                axes[3] = -zgc_axis(pad.rightThumbstick.yAxis);
            }
        }
    }
    return ok;
}

// A retained controller the framework makes for tests, of the extended
// gamepad profile: A pressed, the right trigger at 0.6, the left stick at
// (0.5, 0.25) going up and the d-pad up. NULL where the system cannot.
void *zgc_test_controller(void) {
    GCController *controller = nil;
    @autoreleasepool {
        if (![GCController respondsToSelector:@selector(controllerWithExtendedGamepad)]) return NULL;
        controller = [[GCController controllerWithExtendedGamepad] retain];
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (pad == nil) {
            [controller release];
            return NULL;
        }
        [pad.buttonA setValue:1];
        [pad.rightTrigger setValue:0.6f];
        [pad.leftThumbstick setValueForXAxis:0.5f yAxis:0.25f];
        [pad.dpad setValueForXAxis:0 yAxis:1];
    }
    return controller;
}
