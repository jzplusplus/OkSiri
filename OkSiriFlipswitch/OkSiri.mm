#line 1 "/Users/jzplusplus/Documents/jailbreak/OkSiri/OkSiriFlipswitch/OkSiri.xm"
#import "FSSwitchDataSource.h"
#import "FSSwitchPanel.h"
#import <notify.h>

@interface OkSiriSwitch : NSObject <FSSwitchDataSource>
@end

@implementation OkSiriSwitch


- (FSSwitchState)stateForSwitchIdentifier:(NSString *)switchIdentifier {
    NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"]];
    
    if (plist) { 
        NSString *pref = [plist objectForKey:@"activate"];
        if (pref) {
            if ([pref boolValue]) {
                return FSSwitchStateOn;
            }
            else {
                return FSSwitchStateOff;
            }
        }
    }

	return FSSwitchStateOff;
}


- (void)applyState:(FSSwitchState)newState forSwitchIdentifier:(NSString *)switchIdentifier {
	if (newState == FSSwitchStateIndeterminate) return;

    NSMutableDictionary* plist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"]];
    
    if (plist) 
    {
        if (newState == FSSwitchStateOn)
        {
            [plist setValue:[NSNumber numberWithBool:YES] forKey:@"activate"];
        }
        else if (newState == FSSwitchStateOff)
        {
            [plist setValue:[NSNumber numberWithBool:NO] forKey:@"activate"];
        }
        
        [plist writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"] atomically:YES];
    }
    
    notify_post("jzplusplus.oksiri/activate");
}

@end
