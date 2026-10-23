/*
 * LegacyPodClawNCController.m
 * LegacyPodClaw - Notification Center Widget Implementation
 *
 * Shows: connection status, quick ask field, last response snippet.
 * Tap opens the full LegacyPodClaw app.
 * Quick ask sends directly to API and shows response inline.
 */

#import "QuickAsk.h"
#import "LegacyPodClawNCController.h"
#import <objc/runtime.h>
#import <objc/message.h>

#define PREFS_PATH @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"
#define WIDGET_HEIGHT 72.0f
#define RESPONSE_TOP 56.0f
#define MAX_HEIGHT 320.0f

@interface LegacyPodClawNCController () <UITextFieldDelegate> {
    UIView *_view;
    UILabel *_titleLabel;
    UILabel *_statusLabel;
    UILabel *_responseLabel;
    UITextField *_quickInput;
    UIButton *_askButton;
    UIActivityIndicatorView *_spinner;
    BOOL _isProcessing;
    CGFloat _height;
    id _ask;
    NSMutableString *_streamBuf;
}
@end

/* notification center opens over the lock screen, so the widget must not run or show answers there */
static BOOL LPCLockedWithPasscode(void) {
    id away = [objc_getClass("SBAwayController") performSelector:@selector(sharedAwayController)];
    BOOL locked = [away respondsToSelector:@selector(isLocked)] && ((BOOL (*)(id, SEL))objc_msgSend)(away, @selector(isLocked));
    if (!locked) return NO;
    id lock = [objc_getClass("SBDeviceLockController") performSelector:@selector(sharedController)];
    /* assume a passcode when the class is missing, so we never skip the check */
    return ![lock respondsToSelector:@selector(isPasswordProtected)]
        || ((BOOL (*)(id, SEL))objc_msgSend)(lock, @selector(isPasswordProtected));
}

/* the tweak links the provider code into springboard; the bundle must not carry a second copy of those classes */
static Class LPCQuickAskClass(void) {
    return NSClassFromString(@"OCQuickAsk");
}

@implementation LegacyPodClawNCController

- (UIView *)view {
    if (!_view) {
        [self _buildView];
    }
    return _view;
}

- (float)viewHeight {
    return _height > 0 ? _height : WIDGET_HEIGHT;
}

- (void)_buildView {
    CGFloat w = [[UIScreen mainScreen] bounds].size.width;
    _view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, WIDGET_HEIGHT)];
    _view.backgroundColor = [UIColor clearColor];

    /* Linen-matching background with slight transparency */
    UIView *bg = [[[UIView alloc] initWithFrame:_view.bounds] autorelease];
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3f];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.layer.cornerRadius = 4;
    bg.layer.masksToBounds = YES;
    [_view addSubview:bg];

    /* Title row */
    /* 100 pt cut the name to "LegacyPodCl..." */
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, 112, 16)];
    _titleLabel.text = @"LegacyPodClaw";
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:13];
    _titleLabel.backgroundColor = [UIColor clearColor];
    [_view addSubview:_titleLabel];

    /* Status (right-aligned on title row) */
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(126, 4, w - 136, 16)];
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    _statusLabel.minimumFontSize = 8;
    _statusLabel.textColor = [UIColor colorWithWhite:0.7f alpha:1];
    _statusLabel.font = [UIFont systemFontOfSize:11];
    _statusLabel.textAlignment = NSTextAlignmentRight;
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_view addSubview:_statusLabel];

    /* Quick input row */
    _quickInput = [[UITextField alloc] initWithFrame:CGRectMake(10, 24, w - 70, 26)];
    _quickInput.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15f];
    _quickInput.textColor = [UIColor whiteColor];
    _quickInput.font = [UIFont systemFontOfSize:12];
    _quickInput.layer.cornerRadius = 13;
    _quickInput.layer.masksToBounds = YES;
    _quickInput.placeholder = @"Quick ask...";
    _quickInput.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _quickInput.delegate = self;
    _quickInput.returnKeyType = UIReturnKeySend;
    _quickInput.autocorrectionType = UITextAutocorrectionTypeDefault;
    UIView *pad = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 26)] autorelease];
    _quickInput.leftView = pad;
    _quickInput.leftViewMode = UITextFieldViewModeAlways;
    _quickInput.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_view addSubview:_quickInput];

    /* Ask button */
    _askButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _askButton.frame = CGRectMake(w - 52, 24, 42, 26);
    _askButton.backgroundColor = [UIColor colorWithRed:0.92f green:0.30f blue:0.30f alpha:0.9f];
    _askButton.layer.cornerRadius = 13;
    _askButton.layer.masksToBounds = YES;
    [_askButton setTitle:@"Ask" forState:UIControlStateNormal];
    [_askButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _askButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    _askButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_askButton addTarget:self action:@selector(_askTapped) forControlEvents:UIControlEventTouchUpInside];
    [_view addSubview:_askButton];

    /* Spinner (replaces ask button while processing) */
    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.frame = CGRectMake(w - 30, 28, 18, 18);
    _spinner.hidesWhenStopped = YES;
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_view addSubview:_spinner];

    /* Response area (shown when expanded) */
    _responseLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, RESPONSE_TOP, w - 20, 0)];
    _responseLabel.textColor = [UIColor colorWithWhite:0.9f alpha:1];
    _responseLabel.font = [UIFont systemFontOfSize:12];
    _responseLabel.numberOfLines = 0;
    _responseLabel.backgroundColor = [UIColor clearColor];
    _responseLabel.hidden = YES;
    _responseLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _responseLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_view addSubview:_responseLabel];
}

- (void)dealloc {
    [_view release]; [_titleLabel release]; [_statusLabel release];
    [_responseLabel release]; [_quickInput release]; [_askButton release];
    [_spinner release];
    [_ask cancel];
    [_ask release]; [_streamBuf release];
    [super dealloc];
}

#pragma mark - Lifecycle

- (void)viewWillAppear {
    [self _refreshStatus];
    if (LPCLockedWithPasscode()) {
        [_ask cancel];
        _isProcessing = NO;
        _askButton.hidden = NO;
        [_spinner stopAnimating];
        _responseLabel.text = @"";
        _responseLabel.hidden = YES;
        _height = 0;
        _view.frame = CGRectMake(_view.frame.origin.x, _view.frame.origin.y, _view.bounds.size.width, WIDGET_HEIGHT);
        _quickInput.enabled = NO;
        _quickInput.placeholder = @"Unlock to ask";
    } else {
        _quickInput.enabled = YES;
    }
}

- (void)viewDidAppear {
    [self _refreshStatus];
}

- (NSURL *)launchURL {
    return [NSURL URLWithString:@"openclaw://"];
}

- (NSURL *)launchURLForTapLocation:(CGPoint)location {
    /* Only launch app if tapping on the title area, not the input */
    if (location.y < 22) {
        return [NSURL URLWithString:@"openclaw://"];
    }
    return nil; /* Don't launch — let the input field handle taps */
}

#pragma mark - Status

- (void)_refreshStatus {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *host = [prefs objectForKey:@"gatewayHost"];
    Class qa = LPCQuickAskClass();

    if (host && [host length] > 0) {
        _statusLabel.text = host;
        _statusLabel.textColor = [UIColor colorWithRed:0.4f green:0.9f blue:0.5f alpha:1];
    } else if (qa && [qa isConfigured:prefs]) {
        _statusLabel.text = [[qa providerForPrefs:prefs] displayName];
        _statusLabel.textColor = [UIColor colorWithRed:0.5f green:0.75f blue:1 alpha:1];
    } else {
        _statusLabel.text = @"Not Configured";
        _statusLabel.textColor = [UIColor colorWithRed:1 green:0.5f blue:0.3f alpha:1];
    }
}

#pragma mark - Quick Ask

- (void)_askTapped {
    NSString *q = [_quickInput.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([q length] == 0 || _isProcessing) return;
    if (LPCLockedWithPasscode()) {
        [self _showResponse:@"Unlock the device to ask."];
        return;
    }

    [_quickInput resignFirstResponder];
    [self _sendQuery:q];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self _askTapped];
    return NO;
}

- (void)_sendQuery:(NSString *)query {
    Class qa = LPCQuickAskClass();
    if (!qa) {
        [self _showResponse:@"The LegacyPodClaw tweak is not loaded. Respring and try again."];
        return;
    }
    /* the widget uses the provider, model, key and base url chosen in the app */
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    [_ask cancel];
    [_ask release];
    _ask = [[qa alloc] initWithPrefs:prefs];

    _isProcessing = YES;
    _askButton.hidden = YES;
    [_spinner startAnimating];
    [_streamBuf release];
    _streamBuf = [[NSMutableString alloc] init];
    [self _setResponse:@"Thinking..." color:[UIColor colorWithWhite:0.6f alpha:1]];

    NSString *system = @"You are Molty, a concise AI in a Notification Center widget. "
                        "Maximum 2-3 sentences. Be extremely brief.";
    [_ask askWithSystem:system history:@[@{@"role": @"user", @"content": query}] maxTokens:256
        onText:^(NSString *delta) {
            [_streamBuf appendString:delta];
            [self _setResponse:_streamBuf color:[UIColor colorWithWhite:0.9f alpha:1]];
        }
        completion:^(NSString *text, NSError *error) {
            if (error) {
                id provider = [_ask provider];
                NSString *model = [_ask model];
                [self _showResponse:[NSString stringWithFormat:@"%@ (%@ \u00b7 %@)", [error localizedDescription],
                                     [provider displayName], [model length] ? model : @"no model set"]];
                return;
            }
            _isProcessing = NO;
            _askButton.hidden = NO;
            [_spinner stopAnimating];
            _quickInput.text = @"";
            if ([_streamBuf length] == 0) [self _setResponse:[text length] ? text : @"(no reply)" color:[UIColor colorWithWhite:0.9f alpha:1]];
        }];
}

#pragma mark - Display

- (void)_showResponse:(NSString *)text {
    _isProcessing = NO;
    _askButton.hidden = NO;
    [_spinner stopAnimating];
    [self _setResponse:text color:[UIColor colorWithWhite:0.9f alpha:1]];
}

/* the row height follows the text, or a long answer draws over the rows below the widget */
- (void)_setResponse:(NSString *)text color:(UIColor *)color {
    _responseLabel.hidden = NO;
    _responseLabel.textColor = color;
    _responseLabel.text = text;

    CGFloat w = _view.bounds.size.width;
    CGFloat maxText = MAX_HEIGHT - RESPONSE_TOP - 8;
    CGSize fit = [text sizeWithFont:_responseLabel.font constrainedToSize:CGSizeMake(w - 20, maxText)
                      lineBreakMode:NSLineBreakByWordWrapping];
    CGFloat textH = ceilf(fit.height);
    _responseLabel.frame = CGRectMake(10, RESPONSE_TOP, w - 20, textH);

    CGFloat height = RESPONSE_TOP + textH + 8;
    if (height == _height) return;
    _height = height;
    _view.frame = CGRectMake(_view.frame.origin.x, _view.frame.origin.y, w, height);
    [self _relayoutHost];
}

/* notification center reads viewHeight only when its table recomputes row heights */
- (void)_relayoutHost {
    UIView *v = _view.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    UITableView *table = (UITableView *)v;
    [table beginUpdates];
    [table endUpdates];
    /* the "No New Notifications" label sits below the rows and moves only when the list view asks it to */
    SEL position = @selector(_positionNoNotificationsLabel);
    while (v && ![v respondsToSelector:position]) v = v.superview;
    if (v) {
        [v performSelector:position];
        /* again once the row height animation has changed the content size */
        [v performSelector:position withObject:nil afterDelay:0.35];
    }
}

@end
