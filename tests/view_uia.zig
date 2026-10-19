//! Windows UI Automation check for declarative tabs, toolbars, splits,
//! segments, links, disclosures, breadcrumbs, meters, ratings and
//! accordions, list boxes, form fields and fieldsets, plus combo boxes,
//! search regions, tooltips, avatars and toasts, then trees, tables and
//! token fields, read and driven by a real client on a worker thread.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
    @cInclude("oleauto.h");
});

fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("view UIA HRESULT 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.UiaCallFailed;
    }
}
fn paint(window: z.Window) void {
    _ = c.InvalidateRect(window.nativeHandle(), null, 0);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
}
fn release(object: anytype) void {
    _ = object.lpVtbl.*.Release.?(object);
}

const State = struct {
    section: enum { general, advanced } = .general,
    pane: f64 = 0.5,
    saved: usize = 0,
    mode: enum { light, dark } = .light,
    more: bool = false,
    opened: usize = 0,
    score: u8 = 2,
    open: ?enum { details, reviews } = .details,
    age: f64 = 30,
    terms: bool = false,
    font: usize = 0,
    fonts: view.ScrollModel = .{},
    face: usize = 0,
    back: usize = 0,
    notices: view.Toasts(1) = .{},
    fn build(self: *State, v: *view.View) anyerror!void {
        try v.search(.{ .name = "Find" });
        try v.comboBox(faces[self.face], .{ .name = "Typeface" });
        for (faces, 0..) |face, i| _ = try v.comboOption(usize, &self.face, i, face, .{});
        try v.end();
        if (try v.navButton(.back, .{})) self.back += 1;
        try v.avatar("Ada Lovelace", null, .{});
        try v.end();
        try v.toolbar(.{ .gap = 8, .name = "Actions" });
        if (try v.button("Save", .{})) self.saved += 1;
        try v.tooltip("Save the document");
        try v.end();
        try v.tabs(.{ .name = "Sections" });
        _ = try v.tab(@TypeOf(self.section), &self.section, .general, "General", .{});
        _ = try v.tab(@TypeOf(self.section), &self.section, .advanced, "Advanced", .{});
        try v.end();
        _ = try v.split(.row, &self.pane, .{ .minimum = 0.2, .maximum = 0.8 }, .{ .height = 60, .self_align = .stretch, .name = "Panes" });
        try v.text(if (self.section == .general) "General pane" else "Advanced pane", .{});
        try v.text("Detail", .{});
        try v.end();
        try v.segmented(.{ .name = "Mode" });
        _ = try v.segment(@TypeOf(self.mode), &self.mode, .light, "Light", .{});
        _ = try v.segment(@TypeOf(self.mode), &self.mode, .dark, "Dark", .{});
        try v.end();
        if (try v.link("Help", .{})) self.opened += 1;
        _ = try v.disclosure(&self.more, "More", .{});
        try v.breadcrumbs(.{ .name = "Location" });
        _ = try v.link("Library", .{});
        try v.text("Dune", .{});
        try v.end();
        try v.meter(420, .{ .minimum = 0, .maximum = 512 }, .{ .high = 400 }, .{ .name = "Storage" });
        _ = try v.rating(&self.score, 5, .{ .name = "Score" });
        try v.accordion(.{ .name = "About" });
        _ = try v.section(@TypeOf(self.open.?), &self.open, .details, "Details", .{});
        _ = try v.section(@TypeOf(self.open.?), &self.open, .reviews, "Reviews", .{});
        try v.end();
        try v.scroll(&self.fonts, .{ .height = 60, .self_align = .stretch });
        try v.listBox(.{ .name = "Fonts" });
        for ([_][]const u8{ "Serif", "Sans", "Mono", "Display" }, 0..) |name, i| _ = try v.listItem(usize, &self.font, i, name, .{ .key = i });
        try v.end();
        try v.end();
        try v.fieldset("Account", .{});
        try v.row(.{ .gap = 16 });
        try v.field("Age", .{ .help = "Whole years" }, .{});
        _ = try v.stepper(&self.age, .{ .minimum = 0, .maximum = 120, .step = 1 }, .{});
        try v.end();
        try v.field("Terms", .{ .@"error" = if (self.terms) null else "Accept to continue", .required = true }, .{});
        _ = try v.checkbox(&self.terms, "I accept", .{});
        try v.end();
        try v.end();
        try v.end();
        _ = try v.toasts(&self.notices, .{});
    }
    const faces = [_][]const u8{ "Roman", "Italic" };
};

const Client = struct {
    app: *z.App,
    window: z.Window,
    /// Read on the owner thread; the worker never touches the Window handle.
    hwnd: c.HWND,
    fence: c.HANDLE,
    body: *const fn (*Client, *c.IUIAutomation, *c.IUIAutomationElement, *c.IUIAutomationElementArray, *c.IUIAutomationTreeWalker) anyerror!void,
    err: ?anyerror = null,

    /// Repaint on the owner thread after earlier UIA requests, so the next
    /// read sees the published tree.
    fn synchronize(self: *Client) !void {
        _ = c.ResetEvent(self.fence);
        try self.app.post(.{ .context = self, .call = update });
        if (c.WaitForSingleObject(self.fence, 5000) != c.WAIT_OBJECT_0) return error.FenceTimeout;
    }
    fn update(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        paint(self.window);
        _ = c.SetEvent(self.fence);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        _ = self.window.destroy() catch {};
        self.app.quit();
    }
    fn worker(self: *Client) void {
        self.run() catch |err| {
            self.err = err;
        };
        self.app.post(.{ .context = self, .call = finish }) catch {};
    }

    fn named(element: *c.IUIAutomationElement, comptime name: []const u8) !bool {
        const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(name);
        var text: c.BSTR = null;
        try check(element.lpVtbl.*.get_CurrentName.?(element, &text));
        defer c.SysFreeString(text);
        const length = c.SysStringLen(text);
        return length == wide.len and std.mem.eql(u16, @as([*]const u16, @ptrCast(text))[0..length], wide);
    }
    /// The one descendant with this control type and name; the caller releases it.
    fn find(elements: *c.IUIAutomationElementArray, role: c.CONTROLTYPEID, comptime name: []const u8) !*c.IUIAutomationElement {
        var length: c_int = 0;
        try check(elements.lpVtbl.*.get_Length.?(elements, &length));
        var found: ?*c.IUIAutomationElement = null;
        errdefer if (found) |element| release(element);
        var index: c_int = 0;
        while (index < length) : (index += 1) {
            var element: ?*c.IUIAutomationElement = null;
            try check(elements.lpVtbl.*.GetElement.?(elements, index, &element));
            var actual: c.CONTROLTYPEID = 0;
            check(element.?.lpVtbl.*.get_CurrentControlType.?(element.?, &actual)) catch |err| {
                release(element.?);
                return err;
            };
            const match = actual == role and (named(element.?, name) catch |err| {
                release(element.?);
                return err;
            });
            if (!match) {
                release(element.?);
                continue;
            }
            if (found != null) {
                release(element.?);
                return error.DuplicateElement;
            }
            found = element.?;
        }
        return found orelse {
            std.debug.print("view UIA element missing: {s}\n", .{name});
            return error.MissingElement;
        };
    }
    fn property(element: *c.IUIAutomationElement, id: c.PROPERTYID) !c.VARIANT {
        var value: c.VARIANT = undefined;
        try check(element.lpVtbl.*.GetCurrentPropertyValue.?(element, id, &value));
        return value;
    }
    /// The element's parent; the caller releases it.
    fn parentOf(walker: *c.IUIAutomationTreeWalker, element: *c.IUIAutomationElement) !*c.IUIAutomationElement {
        var result: ?*c.IUIAutomationElement = null;
        try check(walker.lpVtbl.*.GetParentElement.?(walker, element, &result));
        return result.?;
    }
    fn parentType(walker: *c.IUIAutomationTreeWalker, element: *c.IUIAutomationElement) !c.CONTROLTYPEID {
        var parent: ?*c.IUIAutomationElement = null;
        try check(walker.lpVtbl.*.GetParentElement.?(walker, element, &parent));
        defer release(parent.?);
        var role: c.CONTROLTYPEID = 0;
        try check(parent.?.lpVtbl.*.get_CurrentControlType.?(parent.?, &role));
        return role;
    }

    fn run(self: *Client) !void {
        try check(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var api: ?*c.IUIAutomation = null;
        try check(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&api)));
        defer release(api.?);
        var root: ?*c.IUIAutomationElement = null;
        try check(api.?.lpVtbl.*.ElementFromHandle.?(api.?, self.hwnd, &root));
        defer release(root.?);
        var condition: ?*c.IUIAutomationCondition = null;
        try check(api.?.lpVtbl.*.CreateTrueCondition.?(api.?, &condition));
        defer release(condition.?);
        var elements: ?*c.IUIAutomationElementArray = null;
        try check(root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition.?, &elements));
        defer release(elements.?);
        var walker: ?*c.IUIAutomationTreeWalker = null;
        try check(api.?.lpVtbl.*.get_ControlViewWalker.?(api.?, &walker));
        defer release(walker.?);
        try self.body(self, api.?, root.?, elements.?, walker.?);
    }
    /// Every descendant of `root`; the caller releases the array.
    fn descendants(api: *c.IUIAutomation, root: *c.IUIAutomationElement) !*c.IUIAutomationElementArray {
        var condition: ?*c.IUIAutomationCondition = null;
        try check(api.lpVtbl.*.CreateTrueCondition.?(api, &condition));
        defer release(condition.?);
        var elements: ?*c.IUIAutomationElementArray = null;
        try check(root.lpVtbl.*.FindAll.?(root, c.TreeScope_Descendants, condition.?, &elements));
        return elements.?;
    }

    fn controls(self: *Client, _: *c.IUIAutomation, _: *c.IUIAutomationElement, all: *c.IUIAutomationElementArray, tree_walker: *c.IUIAutomationTreeWalker) !void {
        const elements: ?*c.IUIAutomationElementArray = all;
        const walker: ?*c.IUIAutomationTreeWalker = tree_walker;
        const toolbar = try find(elements.?, c.UIA_ToolBarControlTypeId, "Actions");
        defer release(toolbar);
        const save = try find(elements.?, c.UIA_ButtonControlTypeId, "Save");
        defer release(save);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_ToolBarControlTypeId), try parentType(walker.?, save));
        const list = try find(elements.?, c.UIA_TabControlTypeId, "Sections");
        defer release(list);
        const advanced = try find(elements.?, c.UIA_TabItemControlTypeId, "Advanced");
        defer release(advanced);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_TabControlTypeId), try parentType(walker.?, advanced));
        const splitter = try find(elements.?, c.UIA_ThumbControlTypeId, "Panes");
        defer release(splitter);

        // The tab list offers single selection; selecting a tab runs the same
        // activation as a click.
        var selection: ?*c.IUIAutomationSelectionPattern = null;
        try check(list.lpVtbl.*.GetCurrentPatternAs.?(list, c.UIA_SelectionPatternId, &c.IID_IUIAutomationSelectionPattern, @ptrCast(&selection)));
        defer release(selection.?);
        var multiple: c.BOOL = 1;
        try check(selection.?.lpVtbl.*.get_CurrentCanSelectMultiple.?(selection.?, &multiple));
        try std.testing.expectEqual(@as(c.BOOL, 0), multiple);
        var item: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(advanced.lpVtbl.*.GetCurrentPatternAs.?(advanced, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&item)));
        defer release(item.?);
        var selected: c.BOOL = 1;
        try check(item.?.lpVtbl.*.get_CurrentIsSelected.?(item.?, &selected));
        try std.testing.expectEqual(@as(c.BOOL, 0), selected);
        try check(item.?.lpVtbl.*.Select.?(item.?));
        try self.synchronize();
        try check(item.?.lpVtbl.*.get_CurrentIsSelected.?(item.?, &selected));
        try std.testing.expect(selected != 0);

        // The splitter reports the first pane's share within its limits.
        var range: ?*c.IUIAutomationRangeValuePattern = null;
        try check(splitter.lpVtbl.*.GetCurrentPatternAs.?(splitter, c.UIA_RangeValuePatternId, &c.IID_IUIAutomationRangeValuePattern, @ptrCast(&range)));
        defer release(range.?);
        var value: f64 = 0;
        try check(range.?.lpVtbl.*.get_CurrentMinimum.?(range.?, &value));
        try std.testing.expectEqual(@as(f64, 0.2), value);
        try check(range.?.lpVtbl.*.get_CurrentMaximum.?(range.?, &value));
        try std.testing.expectEqual(@as(f64, 0.8), value);
        try check(range.?.lpVtbl.*.get_CurrentValue.?(range.?, &value));
        try std.testing.expectEqual(@as(f64, 0.5), value);
        try std.testing.expectEqual(@as(c.HRESULT, c.E_INVALIDARG), range.?.lpVtbl.*.SetValue.?(range.?, 0.9));
        try check(range.?.lpVtbl.*.SetValue.?(range.?, 0.6));
        try self.synchronize();
        try check(range.?.lpVtbl.*.get_CurrentValue.?(range.?, &value));
        try std.testing.expectApproxEqAbs(@as(f64, 0.6), value, 1e-9);

        // Segments are radios, links invoke and disclosures expand.
        const dark = try find(elements.?, c.UIA_RadioButtonControlTypeId, "Dark");
        defer release(dark);
        var segment: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(dark.lpVtbl.*.GetCurrentPatternAs.?(dark, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&segment)));
        defer release(segment.?);
        try check(segment.?.lpVtbl.*.Select.?(segment.?));
        const help = try find(elements.?, c.UIA_HyperlinkControlTypeId, "Help");
        defer release(help);
        var invoke: ?*c.IUIAutomationInvokePattern = null;
        try check(help.lpVtbl.*.GetCurrentPatternAs.?(help, c.UIA_InvokePatternId, &c.IID_IUIAutomationInvokePattern, @ptrCast(&invoke)));
        defer release(invoke.?);
        try check(invoke.?.lpVtbl.*.Invoke.?(invoke.?));
        const more = try find(elements.?, c.UIA_ButtonControlTypeId, "More");
        defer release(more);
        var expander: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(more.lpVtbl.*.GetCurrentPatternAs.?(more, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&expander)));
        defer release(expander.?);
        var expansion: c.enum_ExpandCollapseState = c.ExpandCollapseState_Expanded;
        try check(expander.?.lpVtbl.*.get_CurrentExpandCollapseState.?(expander.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Collapsed), expansion);
        try check(expander.?.lpVtbl.*.Expand.?(expander.?));
        try self.synchronize();
        // Expanding an expanded disclosure changes nothing.
        try check(expander.?.lpVtbl.*.Expand.?(expander.?));
        try self.synchronize();
        try check(expander.?.lpVtbl.*.get_CurrentExpandCollapseState.?(expander.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Expanded), expansion);

        // Breadcrumb links sit in a navigation landmark.
        const library = try find(elements.?, c.UIA_HyperlinkControlTypeId, "Library");
        defer release(library);
        const trail = try parentOf(walker.?, library);
        defer release(trail);
        try std.testing.expect(try named(trail, "Location"));
        var landmark = try property(trail, c.UIA_LandmarkTypePropertyId);
        try std.testing.expectEqual(@as(c.VARTYPE, c.VT_I4), landmark.unnamed_0.unnamed_0.vt);
        try std.testing.expectEqual(@as(c_long, c.UIA_NavigationLandmarkTypeId), landmark.unnamed_0.unnamed_0.unnamed_0.lVal);
        _ = c.VariantClear(&landmark);

        // A meter reports its own range and refuses changes.
        const storage = try find(elements.?, c.UIA_ProgressBarControlTypeId, "Storage");
        defer release(storage);
        var kind = try property(storage, c.UIA_LocalizedControlTypePropertyId);
        defer _ = c.VariantClear(&kind);
        try std.testing.expectEqual(@as(c.VARTYPE, c.VT_BSTR), kind.unnamed_0.unnamed_0.vt);
        const kind_text = kind.unnamed_0.unnamed_0.unnamed_0.bstrVal;
        try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("meter"), @as([*]const u16, @ptrCast(kind_text))[0..c.SysStringLen(kind_text)]);
        var gauge: ?*c.IUIAutomationRangeValuePattern = null;
        try check(storage.lpVtbl.*.GetCurrentPatternAs.?(storage, c.UIA_RangeValuePatternId, &c.IID_IUIAutomationRangeValuePattern, @ptrCast(&gauge)));
        defer release(gauge.?);
        var read_only: c.BOOL = 0;
        try check(gauge.?.lpVtbl.*.get_CurrentIsReadOnly.?(gauge.?, &read_only));
        try std.testing.expect(read_only != 0);
        try check(gauge.?.lpVtbl.*.get_CurrentValue.?(gauge.?, &value));
        try std.testing.expectEqual(@as(f64, 420), value);
        try check(gauge.?.lpVtbl.*.get_CurrentMaximum.?(gauge.?, &value));
        try std.testing.expectEqual(@as(f64, 512), value);
        try std.testing.expect(gauge.?.lpVtbl.*.SetValue.?(gauge.?, 100) < 0);

        // A rating is a whole-number slider.
        const score = try find(elements.?, c.UIA_SliderControlTypeId, "Score");
        defer release(score);
        var stars: ?*c.IUIAutomationRangeValuePattern = null;
        try check(score.lpVtbl.*.GetCurrentPatternAs.?(score, c.UIA_RangeValuePatternId, &c.IID_IUIAutomationRangeValuePattern, @ptrCast(&stars)));
        defer release(stars.?);
        try check(stars.?.lpVtbl.*.get_CurrentMaximum.?(stars.?, &value));
        try std.testing.expectEqual(@as(f64, 5), value);
        try check(stars.?.lpVtbl.*.SetValue.?(stars.?, 4));
        try self.synchronize();

        // Accordion sections are expanders grouped together; expanding one
        // closes the other.
        const reviews = try find(elements.?, c.UIA_ButtonControlTypeId, "Reviews");
        defer release(reviews);
        const about = try parentOf(walker.?, reviews);
        defer release(about);
        try std.testing.expect(try named(about, "About"));
        var section: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(reviews.lpVtbl.*.GetCurrentPatternAs.?(reviews, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&section)));
        defer release(section.?);
        try check(section.?.lpVtbl.*.Expand.?(section.?));
        try self.synchronize();
        const details = try find(elements.?, c.UIA_ButtonControlTypeId, "Details");
        defer release(details);
        var other: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(details.lpVtbl.*.GetCurrentPatternAs.?(details, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&other)));
        defer release(other.?);
        try check(other.?.lpVtbl.*.get_CurrentExpandCollapseState.?(other.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Collapsed), expansion);

        // Field controls take the label as a missing name, announce the help
        // or error as help text and report validity; the fieldset groups them.
        const age = try find(elements.?, c.UIA_SpinnerControlTypeId, "Age");
        defer release(age);
        try expectText(age, c.UIA_HelpTextPropertyId, "Whole years");
        const accept = try find(elements.?, c.UIA_CheckBoxControlTypeId, "I accept");
        defer release(accept);
        const account = try parentOf(walker.?, accept);
        defer release(account);
        try std.testing.expect(try named(account, "Account"));
        try expectText(accept, c.UIA_HelpTextPropertyId, "Accept to continue");
        try expectFlag(accept, c.UIA_IsDataValidForFormPropertyId, false);
        try expectFlag(accept, c.UIA_IsRequiredForFormPropertyId, true);
        var toggle: ?*c.IUIAutomationTogglePattern = null;
        try check(accept.lpVtbl.*.GetCurrentPatternAs.?(accept, c.UIA_TogglePatternId, &c.IID_IUIAutomationTogglePattern, @ptrCast(&toggle)));
        defer release(toggle.?);
        try check(toggle.?.lpVtbl.*.Toggle.?(toggle.?));
        try self.synchronize();
        try expectFlag(accept, c.UIA_IsDataValidForFormPropertyId, true);

        // A list box offers single selection over its options.
        const fonts = try find(elements.?, c.UIA_ListControlTypeId, "Fonts");
        defer release(fonts);
        var choice: ?*c.IUIAutomationSelectionPattern = null;
        try check(fonts.lpVtbl.*.GetCurrentPatternAs.?(fonts, c.UIA_SelectionPatternId, &c.IID_IUIAutomationSelectionPattern, @ptrCast(&choice)));
        defer release(choice.?);
        try check(choice.?.lpVtbl.*.get_CurrentCanSelectMultiple.?(choice.?, &multiple));
        try std.testing.expectEqual(@as(c.BOOL, 0), multiple);
        const sans = try find(elements.?, c.UIA_ListItemControlTypeId, "Sans");
        defer release(sans);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_ListControlTypeId), try parentType(walker.?, sans));
        var option: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(sans.lpVtbl.*.GetCurrentPatternAs.?(sans, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&option)));
        defer release(option.?);
        try check(option.?.lpVtbl.*.Select.?(option.?));
        try self.synchronize();
        try check(option.?.lpVtbl.*.get_CurrentIsSelected.?(option.?, &selected));
        try std.testing.expect(selected != 0);

        // A combo box reports its value read-only and opens its list through
        // ExpandCollapse, inside a search landmark.
        const typeface = try find(elements.?, c.UIA_ComboBoxControlTypeId, "Typeface");
        defer release(typeface);
        const find_region = try parentOf(walker.?, typeface);
        defer release(find_region);
        try std.testing.expect(try named(find_region, "Find"));
        landmark = try property(find_region, c.UIA_LandmarkTypePropertyId);
        try std.testing.expectEqual(@as(c_long, c.UIA_SearchLandmarkTypeId), landmark.unnamed_0.unnamed_0.unnamed_0.lVal);
        _ = c.VariantClear(&landmark);
        var current: ?*c.IUIAutomationValuePattern = null;
        try check(typeface.lpVtbl.*.GetCurrentPatternAs.?(typeface, c.UIA_ValuePatternId, &c.IID_IUIAutomationValuePattern, @ptrCast(&current)));
        defer release(current.?);
        try check(current.?.lpVtbl.*.get_CurrentIsReadOnly.?(current.?, &read_only));
        try std.testing.expect(read_only != 0);
        try expectText(typeface, c.UIA_ValueValuePropertyId, "Roman");
        var dropdown: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(typeface.lpVtbl.*.GetCurrentPatternAs.?(typeface, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&dropdown)));
        defer release(dropdown.?);
        try check(dropdown.?.lpVtbl.*.Expand.?(dropdown.?));
        try self.synchronize();
        try check(dropdown.?.lpVtbl.*.get_CurrentExpandCollapseState.?(dropdown.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Expanded), expansion);
        try check(dropdown.?.lpVtbl.*.Collapse.?(dropdown.?));
        try self.synchronize();
        try check(dropdown.?.lpVtbl.*.get_CurrentExpandCollapseState.?(dropdown.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Collapsed), expansion);

        // Navigation buttons invoke, avatars are images and a tooltip is
        // its control's help text.
        const back = try find(elements.?, c.UIA_ButtonControlTypeId, "Back");
        defer release(back);
        var step: ?*c.IUIAutomationInvokePattern = null;
        try check(back.lpVtbl.*.GetCurrentPatternAs.?(back, c.UIA_InvokePatternId, &c.IID_IUIAutomationInvokePattern, @ptrCast(&step)));
        defer release(step.?);
        try check(step.?.lpVtbl.*.Invoke.?(step.?));
        const portrait = try find(elements.?, c.UIA_ImageControlTypeId, "Ada Lovelace");
        release(portrait);
        try expectText(save, c.UIA_HelpTextPropertyId, "Save the document");
        try self.synchronize();

        // A toast is a polite live region named by its message.
        const notice = try find(elements.?, c.UIA_GroupControlTypeId, "Draft saved");
        defer release(notice);
        var live = try property(notice, c.UIA_LiveSettingPropertyId);
        try std.testing.expectEqual(@as(c.VARTYPE, c.VT_I4), live.unnamed_0.unnamed_0.vt);
        try std.testing.expectEqual(@as(c_long, c.Polite), live.unnamed_0.unnamed_0.unnamed_0.lVal);
        _ = c.VariantClear(&live);
    }

    fn collections(self: *Client, api: *c.IUIAutomation, root: *c.IUIAutomationElement, elements: *c.IUIAutomationElementArray, walker: *c.IUIAutomationTreeWalker) !void {
        // A tree holds tree items that expand and collapse; a leaf reports
        // that it has nothing to expand.
        const folders = try find(elements, c.UIA_TreeControlTypeId, "Folders");
        defer release(folders);
        const projects = try find(elements, c.UIA_TreeItemControlTypeId, "Projects");
        defer release(projects);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_TreeControlTypeId), try parentType(walker, projects));
        var expander: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(projects.lpVtbl.*.GetCurrentPatternAs.?(projects, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&expander)));
        defer release(expander.?);
        var expansion: c.enum_ExpandCollapseState = c.ExpandCollapseState_Expanded;
        try check(expander.?.lpVtbl.*.get_CurrentExpandCollapseState.?(expander.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Collapsed), expansion);
        try check(expander.?.lpVtbl.*.Expand.?(expander.?));
        try self.synchronize();
        try check(expander.?.lpVtbl.*.get_CurrentExpandCollapseState.?(expander.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Expanded), expansion);
        const expanded = try descendants(api, root);
        defer release(expanded);
        const child = try find(expanded, c.UIA_TreeItemControlTypeId, "Ziggurat");
        defer release(child);
        const owner = try parentOf(walker, child);
        defer release(owner);
        try std.testing.expect(try named(owner, "Projects"));
        var leaf: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(child.lpVtbl.*.GetCurrentPatternAs.?(child, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&leaf)));
        defer release(leaf.?);
        try check(leaf.?.lpVtbl.*.get_CurrentExpandCollapseState.?(leaf.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_LeafNode), expansion);
        const archive = try find(expanded, c.UIA_TreeItemControlTypeId, "Archive");
        defer release(archive);
        var item: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(archive.lpVtbl.*.GetCurrentPatternAs.?(archive, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&item)));
        defer release(item.?);
        try check(item.?.lpVtbl.*.Select.?(item.?));
        try self.synchronize();
        var selected: c.BOOL = 0;
        try check(item.?.lpVtbl.*.get_CurrentIsSelected.?(item.?, &selected));
        try std.testing.expect(selected != 0);

        // A table is a data grid with invokable column headers that report
        // their sort, and rows that join a multiple selection.
        const files = try find(expanded, c.UIA_DataGridControlTypeId, "Files");
        defer release(files);
        var selection: ?*c.IUIAutomationSelectionPattern = null;
        try check(files.lpVtbl.*.GetCurrentPatternAs.?(files, c.UIA_SelectionPatternId, &c.IID_IUIAutomationSelectionPattern, @ptrCast(&selection)));
        defer release(selection.?);
        var multiple: c.BOOL = 0;
        try check(selection.?.lpVtbl.*.get_CurrentCanSelectMultiple.?(selection.?, &multiple));
        try std.testing.expect(multiple != 0);
        const size = try find(expanded, c.UIA_HeaderItemControlTypeId, "Size");
        defer release(size);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_HeaderControlTypeId), try parentType(walker, size));
        var invoke: ?*c.IUIAutomationInvokePattern = null;
        try check(size.lpVtbl.*.GetCurrentPatternAs.?(size, c.UIA_InvokePatternId, &c.IID_IUIAutomationInvokePattern, @ptrCast(&invoke)));
        defer release(invoke.?);
        try check(invoke.?.lpVtbl.*.Invoke.?(invoke.?));
        try self.synchronize();
        try expectText(size, c.UIA_ItemStatusPropertyId, "ascending");
        inline for (.{ "alpha.txt", "gamma.txt" }) |name| {
            const row = try find(expanded, c.UIA_DataItemControlTypeId, name);
            defer release(row);
            var row_item: ?*c.IUIAutomationSelectionItemPattern = null;
            try check(row.lpVtbl.*.GetCurrentPatternAs.?(row, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&row_item)));
            defer release(row_item.?);
            try check(row_item.?.lpVtbl.*.AddToSelection.?(row_item.?));
            try self.synchronize();
        }

        // Tokens are items of their field, each with a remove button.
        const tags = try find(expanded, c.UIA_ListControlTypeId, "Tags");
        defer release(tags);
        try expectText(tags, c.UIA_LocalizedControlTypePropertyId, "token field");
        const green = try find(expanded, c.UIA_ListItemControlTypeId, "green");
        defer release(green);
        try expectText(green, c.UIA_LocalizedControlTypePropertyId, "token");
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_ListControlTypeId), try parentType(walker, green));
    }
    fn expectFlag(element: *c.IUIAutomationElement, id: c.PROPERTYID, expected: bool) !void {
        var value = try property(element, id);
        defer _ = c.VariantClear(&value);
        try std.testing.expectEqual(@as(c.VARTYPE, c.VT_BOOL), value.unnamed_0.unnamed_0.vt);
        try std.testing.expectEqual(expected, value.unnamed_0.unnamed_0.unnamed_0.boolVal != 0);
    }
    fn expectText(element: *c.IUIAutomationElement, id: c.PROPERTYID, comptime expected: []const u8) !void {
        var value = try property(element, id);
        defer _ = c.VariantClear(&value);
        try std.testing.expectEqual(@as(c.VARTYPE, c.VT_BSTR), value.unnamed_0.unnamed_0.vt);
        const text = value.unnamed_0.unnamed_0.unnamed_0.bstrVal;
        try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(expected), @as([*]const u16, @ptrCast(text))[0..c.SysStringLen(text)]);
    }
};

pub fn run(allocator: std.mem.Allocator) !void {
    if (!ui.capabilities.accessibility) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    _ = try state.notices.show("Draft saved", .{ .duration = 0 });
    var storage: view.Storage(64, 768) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = 360, .height = 940 });
    try host.attach(window);
    paint(window);
    if (host.last_error) |err| return err;
    const fence = c.CreateEventW(null, 1, 0, null) orelse return error.EventCreationFailed;
    defer _ = c.CloseHandle(fence);
    var client: Client = .{ .app = app, .window = window, .hwnd = window.nativeHandle(), .fence = fence, .body = Client.controls };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const thread = try std.Thread.spawn(.{}, Client.worker, .{&client});
    defer thread.join();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (client.err) |err| return err;
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(.advanced, state.section);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), state.pane, 1e-9);
    try std.testing.expectEqual(.dark, state.mode);
    try std.testing.expectEqual(@as(usize, 1), state.opened);
    try std.testing.expect(state.more);
    try std.testing.expectEqual(@as(u8, 4), state.score);
    try std.testing.expectEqual(.reviews, state.open.?);
    try std.testing.expect(state.terms);
    try std.testing.expectEqual(@as(usize, 1), state.font);
    try std.testing.expectEqual(@as(usize, 1), state.back);
    try std.testing.expectEqual(@as(usize, 0), state.face);
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
    try runCollections(allocator);
    std.debug.print("view UIA smoke passed: real client tab list/tab selection, toolbar parent, splitter RangeValue, segment selection, link invoke, disclosure ExpandCollapse, navigation landmark, read-only meter, rating RangeValue, accordion sections, form field help/validity, list box selection, combo box Value/ExpandCollapse, search landmark, navigation button, image and tooltip help text, tree ExpandCollapse/selection, data grid header sort and multiple row selection, token field items\n", .{});
}

const Collections = struct {
    open: bool = false,
    tree_storage: [2]u64 = undefined,
    tree: view.Selection = undefined,
    sort: ?view.Sort = null,
    table_storage: [4]u64 = undefined,
    table: view.Selection = undefined,
    tags: [2][]const u8 = .{ "red", "green" },
    fn build(self: *Collections, v: *view.View) anyerror!void {
        try v.tree(&self.tree, .{ .name = "Folders", .self_align = .stretch });
        _ = try v.treeItem(1, &self.open, "Projects", .{});
        if (self.open) {
            _ = try v.treeItem(2, null, "Ziggurat", .{});
            try v.end();
        }
        try v.end();
        _ = try v.treeItem(3, null, "Archive", .{});
        try v.end();
        try v.end();
        const columns = [_]view.Column{ .{ .title = "Name" }, .{ .title = "Size" } };
        _ = try v.table(&columns, &self.sort, &self.table, .{ .name = "Files", .self_align = .stretch });
        for ([_][]const u8{ "alpha.txt", "beta.txt", "gamma.txt" }, 1..) |name, id| {
            _ = try v.tableRow(id, name, .{});
            try v.text(name, .{});
            try v.textf("{d} KB", .{id * 10}, .{});
            try v.end();
        }
        try v.end();
        try v.tokenField(.{ .name = "Tags", .self_align = .stretch });
        for (self.tags) |tag| _ = try v.token(tag, .{ .key = view.key(tag) });
        try v.end();
    }
};

fn runCollections(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: Collections = .{};
    state.tree = .init(.single, &state.tree_storage);
    state.table = .init(.multiple, &state.table_storage);
    var storage: view.Storage(64, 512) = .{};
    var host = view.Host.init(&state, Collections.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = 360, .height = 480 });
    try host.attach(window);
    paint(window);
    if (host.last_error) |err| return err;
    const fence = c.CreateEventW(null, 1, 0, null) orelse return error.EventCreationFailed;
    defer _ = c.CloseHandle(fence);
    var client: Client = .{ .app = app, .window = window, .hwnd = window.nativeHandle(), .fence = fence, .body = Client.collections };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const thread = try std.Thread.spawn(.{}, Client.worker, .{&client});
    defer thread.join();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (client.err) |err| return err;
    if (host.last_error) |err| return err;
    try std.testing.expect(state.open);
    try std.testing.expectEqualSlices(u64, &.{3}, state.tree.items());
    try std.testing.expectEqual(@as(?view.Sort, .{ .column = 1 }), state.sort);
    try std.testing.expectEqualSlices(u64, &.{ 1, 3 }, state.table.items());
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}
