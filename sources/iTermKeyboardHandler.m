//
//  iTermKeyboardHandler.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 12/29/18.
//

#import "iTermKeyboardHandler.h"

#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermNSKeyBindingEmulator.h"
#import "NSEvent+iTerm.h"
#import "NSStringITerm.h"

// In issue 2743, it is revealed that in OS 10.9 this sometimes calls -insertText on the
// wrong instance of PTYTextView. We work around the issue by using a global variable to
// track the instance of PTYTextView that is currently handling a key event and rerouting
// calls as needed in -insertText and -doCommandBySelector. Post-refactoring, we now keep
// an instance of iTermKeyboardHandler around which is moderately less yucky.
//
// I don't know if or when this bug was ever fixed so the hack lives on out of fear.
static iTermKeyboardHandler *sCurrentKeyboardHandler;

@implementation iTermKeyboardHandler {
    iTermNSKeyBindingEmulator *_keyBindingEmulator;

    NSEvent *_eventBeingHandled;

    // Was the last pressed key a "repeat" where the key is held down?
    BOOL _keyIsARepeat;

    // When an event is passed to -handleEvent, it may get dispatched to -insertText:replacementRange:
    // or -doCommandBySelector:. If one of these methods processes the input by sending it to the
    // delegate then this will be set to YES to prevent it from being handled twice.
    BOOL _keyPressHandled;

    // This is used by the experimental feature guarded by [iTermAdvancedSettingsModel experimentalKeyHandling] or [iTermAdvancedSettingsModel enableCharacterAccentMenu].
    // Indicates if marked text existed before invoking -handleEvent: for a keypress. If the
    // input method handles the keypress and causes the IME to finish then the keypress must not
    // be passed to the delegate. -insertText:replacementRange: and -doCommandBySelector: need to
    // know if marked text existed prior to -handleEvent so they can avoid passing the event to the
    // delegate in this case.
    BOOL _hadMarkedTextBeforeHandlingKeypressEvent;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _keyBindingEmulator = [iTermNSKeyBindingEmulator sharedInstance];
    }
    return self;
}

- (NSDictionary *)dictionaryValue {
    return @{ @"mapper": NSStringFromClass(self.keyMapper.class) ?: @"",
              @"mapperConfig": self.keyMapper.keyMapperDictionaryValue ?: @{} };
}

- (nullable NSString *)stringForEventWithoutSideEffects:(NSEvent *)event encoding:(NSStringEncoding)encoding {
    return [[NSString alloc] initWithData:[_keyMapper keyMapperDataForPostCocoaEvent:event] encoding:encoding];
}

// I haven't figured out how to test this code automatically, but a few things to try:
// * Repeats in US
// * Repeats in AquaSKK's Hiragana
// * Press L in AquaSKK's Hiragana to enter AquaSKK's ASCII
// * "special" keys, like Enter which go through doCommandBySelector
// * Repeated special keys
- (void)keyDown:(NSEvent *)event inputContext:(nonnull NSTextInputContext *)inputContext {
    DLog(@"PTYTextView keyDown BEGIN %@", event);
    if (![self.delegate keyboardHandler:self shouldHandleKeyDown:event]) {
        return;
    }
    unsigned int modflag = [event it_modifierFlags];
    unsigned short keyCode = [event keyCode];
    _hadMarkedTextBeforeHandlingKeypressEvent = [self hasMarkedText];
    BOOL rightAltPressed = (modflag & NSRightAlternateKeyMask) == NSRightAlternateKeyMask;
    BOOL leftAltPressed = (modflag & NSEventModifierFlagOption) == NSEventModifierFlagOption && !rightAltPressed;

    iTermKeyboardHandlerContext context;
    [self.delegate keyboardHandler:self loadContext:&context forEvent:event];
    
    _keyIsARepeat = [event isARepeat];
    DLog(@"PTYTextView keyDown modflag=%d keycode=%d", modflag, (int)keyCode);
    DLog(@"_hadMarkedTextBeforeHandlingKeypressEvent=%d", (int)_hadMarkedTextBeforeHandlingKeypressEvent);
    DLog(@"hasActionableKeyMappingForEvent=%d", (int)context.hasActionableKeyMapping);
    DLog(@"modFlag & (NSEventModifierFlagNumericPad | NSEventModifierFlagFunction)=%lu", (modflag & (NSEventModifierFlagNumericPad | NSEventModifierFlagFunction)));
    DLog(@"charactersIgnoringModifiers length=%d", (int)[[event charactersIgnoringModifiers] length]);
    DLog(@"delegate optionkey=%d, delegate rightOptionKey=%d", context.leftOptionKey, context.rightOptionKey);
    DLog(@"leftAltPressed && optionKey != NORMAL = %d", (int)(leftAltPressed && context.leftOptionKey != OPT_NORMAL));
    DLog(@"rightAltPressed && rightOptionKey != NORMAL = %d", (int)(rightAltPressed && context.rightOptionKey != OPT_NORMAL));
    DLog(@"isControl=%d", (int)(modflag & NSEventModifierFlagControl));
    DLog(@"keycode is slash=%d, is backslash=%d", (keyCode == 0x2c), (keyCode == 0x2a));
    DLog(@"event is repeated=%d", _keyIsARepeat);

    // discard repeated key events if auto repeat mode (DECARM) is disabled
    if (_keyIsARepeat && !context.autorepeatMode) {
        return;
    }

    // Hide the cursor
    [NSCursor setHiddenUntilMouseMoves:YES];

    NSMutableArray *eventsToHandle = [NSMutableArray array];
    BOOL pointlessly;
    if ([_keyBindingEmulator handlesEvent:event pointlessly:&pointlessly extraEvents:eventsToHandle action:nil]) {
        if (!pointlessly) {
            DLog(@"iTermNSKeyBindingEmulator reports that event is handled, sending to interpretKeyEvents.");
            [self.delegate keyboardHandler:self interpretKeyEvents:@[ event ]];
        } else {
            // There is a keybinding action which is not insertText:
            [self handleKeyDownEvent:event eschewCocoaTextHandling:YES context:context inputContext:inputContext];
        }
        return;
    }
    [eventsToHandle addObject:event];
    for (NSEvent *event in eventsToHandle) {
        [self handleKeyDownEvent:event eschewCocoaTextHandling:NO context:context inputContext:inputContext];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event inputContext:(NSTextInputContext *)inputContext {
    DLog(@"event=%@", event);
    if ([_keyMapper keyMapperWantsKeyEquivalent:event]) {
        [self keyDown:event inputContext:inputContext];
        return YES;
    }
    DLog(@"return no");
    return NO;
}

- (void)flagsChanged:(NSEvent *)event {
    [self.delegate keyboardHandler:self sendEventToController:event];
}

#pragma mark - NSTextInputClient

- (void)doCommandBySelector:(SEL)aSelector {
    DLog(@"doCommandBySelector:%@", NSStringFromSelector(aSelector));
    if (sCurrentKeyboardHandler && self != sCurrentKeyboardHandler) {
        // See comment in -keyDown:
        DLog(@"Rerouting doCommandBySelector from %@ to %@", self, sCurrentKeyboardHandler);
        [sCurrentKeyboardHandler doCommandBySelector:aSelector];
        return;
    }

    if ([iTermAdvancedSettingsModel experimentalKeyHandling] || [iTermAdvancedSettingsModel enableCharacterAccentMenu]) {
        // Pass the event to the delegate since doCommandBySelector was called instead of
        // insertText:replacementRange:, unless an IME is in use. An example of when this gets called
        // but we should not pass the event to the delegate is when there is marked text and you press
        // Enter.
        if (![self hasMarkedText] && !_hadMarkedTextBeforeHandlingKeypressEvent && _eventBeingHandled) {
            _keyPressHandled = YES;
            [self.delegate keyboardHandler:self sendEventToController:_eventBeingHandled];
        }
    }
    DLog(@"returning from doCommandBySelector:%@", NSStringFromSelector(aSelector));
}

// TODO: Respect replacementRange
- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange {
    DLog(@"insertText:%@ replacementRange:%@", aString ,NSStringFromRange(replacementRange));
    if ([aString isKindOfClass:[NSAttributedString class]]) {
        aString = [aString string];
    }
    if (sCurrentKeyboardHandler && self != sCurrentKeyboardHandler) {
        // See comment in -keyDown:
        DLog(@"Rerouting insertText from %@ to %@", self, sCurrentKeyboardHandler);
        [sCurrentKeyboardHandler insertText:aString
                           replacementRange:replacementRange];
        return;
    }

    // See issue 6699
    aString = [aString stringByReplacingOccurrencesOfString:@"¥" withString:@"\\"];

    DLog(@"PTYTextView insertText:%@", aString);
    if (replacementRange.length > 0 && replacementRange.location != NSNotFound) {
        DLog(@"Replacement range has length %@", @(replacementRange.length));
        NSEvent *saved = _eventBeingHandled;
        if ([self.delegate keyboardHandler:self shouldBackspaceAt:NSMaxRange(replacementRange)]) {
            DLog(@"Delegate allows us to backspace");
            _eventBeingHandled = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                                  location:NSZeroPoint
                                             modifierFlags:0
                                                 timestamp:0
                                              windowNumber:[self.delegate keyboardHandlerWindowNumber:self]
                                                   context:nil
                                                characters:[NSString stringWithLongCharacter:127]
                               charactersIgnoringModifiers:[NSString stringWithLongCharacter:127]
                                                 isARepeat:NO
                                                   keyCode:kVK_Delete];
            for (NSInteger i = 0; i < replacementRange.length; i++) {
                [self doCommandBySelector:@selector(deleteBackward:)];
            }
            _eventBeingHandled = saved;
        }
    }
    aString = [_keyMapper transformedTextToInsert:aString];
    [self.delegate keyboardHandler:self insertText:aString];
    if ([aString length] > 0) {
        _keyPressHandled = YES;
    }
}

- (BOOL)hasMarkedText {
    return [self.delegate keyboardHandlerMarkedTextRange:self].length > 0;
}

#pragma mark - Private

- (BOOL)shouldSendEventToController:(NSEvent *)event
                            context:(iTermKeyboardHandlerContext)context {
    if (_hadMarkedTextBeforeHandlingKeypressEvent) {
        DLog(@"_hadMarkedTextBeforeHandlingKeypressEvent=YES");
        return NO;
    }

    if (context.hasActionableKeyMapping) {
        // Delegate will do something useful
        DLog(@"context.hasActionableKeyMapping");
        return YES;
    }

    return [_keyMapper keyMapperShouldBypassPreCocoaForEvent:event];
}

- (NSString *)currentKeyboardSourceID {
    TISInputSourceRef source = NULL;
    source = TISCopyCurrentKeyboardInputSource();
    NSString *keyboardID = [(__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID) copy];
    CFRelease(source);
    return keyboardID;
}

- (BOOL)performCheckingIfKeyboardChanges:(void (^)(void))block {
    NSString *keyboardBefore = [self currentKeyboardSourceID];
    block();
    // If our keyboard changed from this we just assume an input method
    // grabbed it and do nothing.
    if (keyboardBefore && ![keyboardBefore isEqualToString:self.currentKeyboardSourceID]) {
        return YES;
    }
    return NO;
}

- (void)sendEventToCocoa:(NSEvent *)event inputContext:(NSTextInputContext *)inputContext {
    _eventBeingHandled = event;
    // TODO: Consider going straight to interpretKeyEvents: for repeats. See issue 6052.
    if ([iTermAdvancedSettingsModel experimentalKeyHandling] || [iTermAdvancedSettingsModel enableCharacterAccentMenu]) {
        // This may cause -insertText:replacementRange: or -doCommandBySelector: to be called.
        // These methods have a side-effect of setting _keyPressHandled if they dispatched the event
        // to the delegate. They might not get called: for example, if you hold down certain keys
        // then repeats might be ignored, or the IME might handle it internally (such as when you press
        // "L" in AquaSKK's Hiragana mode to enter ASCII mode. See pull request 279 for more on this.
        DLog(@"Calling handleEvent:%@", event);
        _keyPressHandled = [inputContext handleEvent:event];
    } else {
        DLog(@"Calling interpretKeyEvents:%@", event);
        [self.delegate keyboardHandler:self interpretKeyEvents:@[ event ]];
    }
    if (_eventBeingHandled == event) {
        _eventBeingHandled = nil;
    }
}

- (BOOL)shouldPassPostCocoaEventToDelegate:(NSEvent *)event inputContext:(NSTextInputContext *)inputContext {
    if (_hadMarkedTextBeforeHandlingKeypressEvent) {
        return NO;
    }
    if (_keyPressHandled) {
        return NO;
    }
    if ([self hasMarkedText]) {
        return NO;
    }
    if ([iTermAdvancedSettingsModel experimentalKeyHandling] || [iTermAdvancedSettingsModel enableCharacterAccentMenu]) {
        if (!event.isARepeat) {
            return NO;
        }
    }
    const NSEventModifierFlags mask = (NSEventModifierFlagOption |
                                       NSEventModifierFlagCommand |
                                       NSEventModifierFlagControl);
    if ([inputContext.selectedKeyboardInputSource isEqual:@"com.apple.keylayout.UnicodeHexInput"] &&
        (event.modifierFlags & mask) == NSEventModifierFlagOption &&
        event.charactersIgnoringModifiers.length == 1 &&
        [@"1234567890abcdefABCDEF" containsString:event.charactersIgnoringModifiers]) {
        DLog(@"Hex input");
        return NO;
    }
    return YES;
}

- (BOOL)shouldAllowPreCocoaKeyMappingForEvent:(NSEvent *)event {
    if (_hadMarkedTextBeforeHandlingKeypressEvent) {
        return NO;
    }

    NSString *charactersIgnoringModifiers = [event charactersIgnoringModifiers];
    if ([charactersIgnoringModifiers length] == 0) {
        // Dead key
        return NO;
    }

    return YES;
}

- (void)handleKeyDownEvent:(NSEvent *)event
   eschewCocoaTextHandling:(BOOL)eschewCocoaTextHandling
                   context:(iTermKeyboardHandlerContext)context
              inputContext:(NSTextInputContext *)inputContext {
    const unsigned int modflag = [event it_modifierFlags];
    [_keyMapper keyMapperSetEvent:event];

    // Should we process the event immediately in the delegate?
    if ([self shouldSendEventToController:event context:context]) {
        DLog(@"PTYTextView keyDown: process in delegate");
        [self.delegate keyboardHandler:self sendEventToController:event];
        return;
    }

    DLog(@"Test for command key");

    if (modflag & NSEventModifierFlagCommand) {
        // You pressed cmd+something but it's not handled by the delegate. Going further would
        // send the unmodified key to the terminal which doesn't make sense.
        DLog(@"PTYTextView keyDown You pressed cmd+something");
        return;
    }

    // Control+Key doesn't work right with custom keyboard layouts. Handle ctrl+key here for the
    // standard combinations.
    if ([self shouldAllowPreCocoaKeyMappingForEvent:event]) {
        NSString *string = [_keyMapper keyMapperStringForPreCocoaEvent:event];
        if (string) {
            const NSRange markedRange = [self.delegate keyboardHandlerMarkedTextRange:self];
            [self insertText:string replacementRange:markedRange];
            return;
        }
    }

    // Let the IME process key events
    _keyPressHandled = NO;
    DLog(@"PTYTextView keyDown send to IME");

    if (eschewCocoaTextHandling) {
        // Go directly to the controller because cocoa will use a key binding action that isn't
        // insertText:.
        [self.delegate keyboardHandler:self
                 sendEventToController:event];
    } else {
        // Normal code path.
        [self handleEventWithCocoa:event
                      inputContext:inputContext];
    }
    DLog(@"PTYTextView keyDown END");
}

- (void)handleEventWithCocoa:(NSEvent *)event
                    inputContext:(NSTextInputContext *)inputContext {
    sCurrentKeyboardHandler = self;
    const BOOL keyboardChanged = [self performCheckingIfKeyboardChanges:^{
        [self sendEventToCocoa:event inputContext:inputContext];
    }];
    sCurrentKeyboardHandler = nil;

    if (keyboardChanged && [iTermAdvancedSettingsModel aquaSKKBugfixEnabled]) {
        // See https://github.com/ghostty-org/ghostty/commit/7a27af8bfce9007e31be10aeafe7a968a66aa0b5#diff-a2fa888dc78c338c8f0e1d250487f2fae439debb3fcf7ff2d1a3ad70616a9fb1
        DLog(@"This event (%@) caused the keyboard to change, so don't process it any more", event);
        return;
    }
    if (event.isARepeat && [iTermAdvancedSettingsModel enableCharacterAccentMenu]) {
        DLog(@"Squelch repeated keypress event %@", event);
        return;
    }
    if ([self shouldPassPostCocoaEventToDelegate:event inputContext:inputContext]) {
        DLog(@"PTYTextView keyDown unhandled (likely repeated) keypress with no IME, send to delegate");
        [self.delegate keyboardHandler:self sendEventToController:event];
    }
}

@end

