//
//  OkSiri.m
//  OkSiri
//
//  Created by Jay Zuerndorfer on 5/25/14.
//  Copyright (c) 2014 Jay Zuerndorfer. All rights reserved.
//

// LibActivator by Ryan Petrich
// See https://github.com/rpetrich/libactivator

#import <Foundation/Foundation.h>
#import <AVFoundation/AVAudioSession.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#include <dlfcn.h>
#import <libactivator/libactivator.h>
#include <logos/logos.h>
#include <substrate.h>
#import <notify.h>
#import "LSStatusBarItem.h"

#import <OpenEars/OELanguageModelGenerator.h>
#import <OpenEars/OEAcousticModel.h>
#import <OpenEars/OEPocketsphinxController.h>
#import <OpenEars/OEEventsObserver.h>
#import <OpenEars/OELogging.h>
//#import <OpenEars/AudioSessionManager.h>

#define ACOUSTIC_MODEL_PATH     @"/Library/OpenEars/AcousticModelEnglish.bundle"
#define DEFAULT_KEYWORD         @"OK SIRI"
#define DEFAULT_SENSITIVITY     5000


@interface OkSiri : NSObject<LAListener, LAEventDataSource, OEEventsObserverDelegate> {
    OEPocketsphinxController *pocketsphinxController;
    OEEventsObserver *openEarsEventsObserver;
    NSString *keyword;
    int sensitivity;
    LSStatusBarItem *statusBarItem;
}

    - (void)startRecognition;
    - (void)stopRecognition;
    - (void)stopRecognitionTemporarily;

    @property (strong, nonatomic) OEPocketsphinxController *pocketsphinxController;
    @property (strong, nonatomic) OEEventsObserver *openEarsEventsObserver;
    @property (strong, nonatomic) NSString *keyword;
    @property (nonatomic) int sensitivity;
    @property (strong, nonatomic) LSStatusBarItem *statusBarItem;
    @property (strong, nonatomic) OELanguageModelGenerator *languageGeneratorResults;

@end

static OkSiri *ok;
static Class _LAActivator;
static Class _LAEvent;
static Class _VSSpeechSynthesizer;
static Class _SBAssistantController;
static Class _VolumeControl;

static void prefChanged()
{
    if([[ok pocketsphinxController] isListening]) [ok stopRecognitionTemporarily];
    
    NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"]];
    
    if (plist) { // Preference file exists
        NSNumber *pref = [plist objectForKey:@"activate"];
        if (pref && [pref boolValue]) {
            [ok startRecognition];
        }
    }
}

@class SBMediaController;
static void (*old_nowPlayingInfoChanged)(SBMediaController*, SEL);
static void new_nowPlayingInfoChanged(SBMediaController*, SEL);

static int dispatchCounter = 0;
static void new_nowPlayingInfoChanged(SBMediaController* self, SEL _cmd) {
	old_nowPlayingInfoChanged(self, _cmd);
    
    if([self isPlaying] && [ok.pocketsphinxController isListening]) [ok stopRecognitionTemporarily];
    
    dispatchCounter++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        dispatchCounter--;
        if(dispatchCounter <= 0)
        {
            dispatchCounter = 0;
            if(![self isPlaying])
            {
                NSLog(@"Restarting OkSiri after media stopped");
                notify_post("jzplusplus.oksiri/activate");
            }
        }

    });
}

@class SBApplication;
static void (*old_willActivate)(SBApplication*, SEL);
static void new_willActivate(SBApplication*, SEL);
static void (*old_didSuspend)(SBApplication*, SEL);
static void new_didSuspend(SBApplication*, SEL);

static void new_willActivate(SBApplication* self, SEL _cmd) {
	old_willActivate(self, _cmd);
    if([@"com.apple.camera" isEqualToString:[self bundleIdentifier]])
    {
        [ok stopRecognitionTemporarily];
    }
}

static void new_didSuspend(SBApplication* self, SEL _cmd) {
	old_didSuspend(self, _cmd);
    if([@"com.apple.camera" isEqualToString:[self bundleIdentifier]])
    {
        prefChanged();
    }
}

@implementation OkSiri

@synthesize pocketsphinxController;
@synthesize openEarsEventsObserver;
@synthesize keyword;
@synthesize sensitivity;
@synthesize statusBarItem;
@synthesize languageGeneratorResults;

- (OEPocketsphinxController *)pocketsphinxController {
	if (pocketsphinxController == nil) {
		pocketsphinxController = [OEPocketsphinxController sharedInstance];
	}
	return pocketsphinxController;
}
- (OEEventsObserver *)openEarsEventsObserver {
	if (openEarsEventsObserver == nil) {
		openEarsEventsObserver = [[OEEventsObserver alloc] init];
	}
	return openEarsEventsObserver;
}

- (void)writeIfActivated:(BOOL)activated
{
    NSMutableDictionary* plist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"]];
    
    if (plist) // Preference file exists
    {
        [plist setValue:[NSNumber numberWithBool:activated] forKey:@"activate"];
        
        [plist writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"] atomically:YES];
    }

}

- (void)generateLanguageModel
{
    OELanguageModelGenerator *lmGenerator = [[OELanguageModelGenerator alloc] init];
    [lmGenerator setVerboseLanguageModelGenerator:YES];
    
    //keyword, plus the most common 500 words (makes recognition less likely to false positive)
    NSArray *words = [NSArray arrayWithObjects:self.keyword, @"THE", @"NAME", @"OF", @"VERY", @"TO", @"THROUGH", @"AND", @"JUST", @"A", @"FORM", @"IN", @"MUCH", @"IS", @"GREAT", @"IT", @"THINK", @"YOU", @"SAY", @"THAT", @"HELP", @"HE", @"LOW", @"WAS", @"LINE", @"FOR", @"BEFORE", @"ON", @"TURN", @"ARE", @"CAUSE", @"WITH", @"SAME", @"AS", @"MEAN", @"I", @"DIFFER", @"HIS", @"MOVE", @"THEY", @"RIGHT", @"BE", @"BOY", @"AT", @"OLD", @"ONE", @"TOO", @"HAVE", @"DOES", @"THIS", @"TELL", @"FROM", @"SENTENCE", @"OR", @"SET", @"HAD", @"THREE", @"BY", @"WANT", @"HOT", @"AIR", @"BUT", @"WELL", @"SOME", @"ALSO", @"WHAT", @"PLAY", @"THERE", @"SMALL", @"WE", @"END", @"CAN", @"PUT", @"OUT", @"HOME", @"OTHER", @"READ", @"WERE", @"HAND", @"ALL", @"PORT", @"YOUR", @"LARGE", @"WHEN", @"SPELL", @"UP", @"ADD", @"USE", @"EVEN", @"WORD", @"LAND", @"HOW", @"HERE", @"SAID", @"MUST", @"AN", @"BIG", @"EACH", @"HIGH", @"SHE", @"SUCH", @"WHICH", @"FOLLOW", @"DO", @"ACT", @"THEIR", @"WHY", @"TIME", @"ASK", @"IF", @"MEN", @"WILL", @"CHANGE", @"WAY", @"WENT", @"ABOUT", @"LIGHT", @"MANY", @"KIND", @"THEN", @"OFF", @"THEM", @"NEED", @"WOULD", @"HOUSE", @"WRITE", @"PICTURE", @"LIKE", @"TRY", @"SO", @"US", @"THESE", @"AGAIN", @"HER", @"ANIMAL", @"LONG", @"POINT", @"MAKE", @"MOTHER", @"THING", @"WORLD", @"SEE", @"NEAR", @"HIM", @"BUILD", @"TWO", @"SELF", @"HAS", @"EARTH", @"LOOK", @"FATHER", @"MORE", @"HEAD", @"DAY", @"STAND", @"COULD", @"OWN", @"GO", @"PAGE", @"COME", @"SHOULD", @"DID", @"COUNTRY", @"MY", @"FOUND", @"SOUND", @"ANSWER", @"NO", @"SCHOOL", @"MOST", @"GROW", @"NUMBER", @"STUDY", @"WHO", @"STILL", @"OVER", @"LEARN", @"KNOW", @"PLANT", @"WATER", @"COVER", @"THAN", @"FOOD", @"CALL", @"SUN", @"FIRST", @"FOUR", @"PEOPLE", @"THOUGHT", @"MAY", @"LET", @"DOWN", @"KEEP", @"SIDE", @"EYE", @"BEEN", @"NEVER", @"NOW", @"LAST", @"FIND", @"DOOR", @"ANY", @"BETWEEN", @"NEW", @"CITY", @"WORK", @"TREE", @"PART", @"CROSS", @"TAKE", @"SINCE", @"GET", @"HARD", @"PLACE", @"START", @"MADE", @"MIGHT", @"LIVE", @"STORY", @"WHERE", @"SAW", @"AFTER", @"FAR", @"BACK", @"SEA", @"LITTLE", @"DRAW", @"ONLY", @"LEFT", @"ROUND", @"LATE", @"MAN", @"RUN", @"YEAR", @"DON'T", @"CAME", @"WHILE", @"SHOW", @"PRESS", @"EVERY", @"CLOSE", @"GOOD", @"NIGHT", @"ME", @"REAL", @"GIVE", @"LIFE", @"OUR", @"FEW", @"UNDER", @"STOP", @"OPEN", @"TEN", @"SEEM", @"SIMPLE", @"TOGETHER", @"SEVERAL", @"NEXT", @"VOWEL", @"WHITE", @"TOWARD", @"CHILDREN", @"WAR", @"BEGIN", @"LAY", @"GOT", @"AGAINST", @"WALK", @"PATTERN", @"EXAMPLE", @"SLOW", @"EASE", @"CENTER", @"PAPER", @"LOVE", @"OFTEN", @"PERSON", @"ALWAYS", @"MONEY", @"MUSIC", @"SERVE", @"THOSE", @"APPEAR", @"BOTH", @"ROAD", @"MARK", @"MAP", @"BOOK", @"SCIENCE", @"LETTER", @"RULE", @"UNTIL", @"GOVERN", @"MILE", @"PULL", @"RIVER", @"COLD", @"CAR", @"NOTICE", @"FEET", @"VOICE", @"CARE", @"FALL", @"SECOND", @"POWER", @"GROUP", @"TOWN", @"CARRY", @"FINE", @"TOOK", @"CERTAIN", @"RAIN", @"FLY", @"EAT", @"UNIT", @"ROOM", @"LEAD", @"FRIEND", @"CRY", @"BEGAN", @"DARK", @"IDEA", @"MACHINE", @"FISH", @"NOTE", @"MOUNTAIN", @"WAIT", @"NORTH", @"PLAN", @"ONCE", @"FIGURE", @"BASE", @"STAR", @"HEAR", @"BOX", @"HORSE", @"NOUN", @"CUT", @"FIELD", @"SURE", @"REST", @"WATCH", @"CORRECT", @"COLOR", @"ABLE", @"FACE", @"POUND", @"WOOD", @"DONE", @"MAIN", @"BEAUTY", @"ENOUGH", @"DRIVE", @"PLAIN", @"STOOD", @"GIRL", @"CONTAIN", @"USUAL", @"FRONT", @"YOUNG", @"TEACH", @"READY", @"WEEK", @"ABOVE", @"FINAL", @"EVER", @"GAVE", @"RED", @"GREEN", @"LIST", @"OH", @"THOUGH", @"QUICK", @"FEEL", @"DEVELOP", @"TALK", @"SLEEP", @"BIRD", @"WARM", @"SOON", @"FREE", @"BODY", @"MINUTE", @"DOG", @"STRONG", @"FAMILY", @"SPECIAL", @"DIRECT", @"MIND", @"POSE", @"BEHIND", @"LEAVE", @"CLEAR", @"SONG", @"TAIL", @"MEASURE", @"PRODUCE", @"STATE", @"FACT", @"PRODUCT", @"STREET", @"BLACK", @"INCH", @"SHORT", @"LOT", @"NUMERAL", @"NOTHING", @"CLASS", @"COURSE", @"WIND", @"STAY", @"QUESTION", @"WHEEL", @"HAPPEN", @"FULL", @"COMPLETE", @"FORCE", @"SHIP", @"BLUE", @"AREA", @"OBJECT", @"HALF", @"DECIDE", @"ROCK", @"SURFACE", @"ORDER", @"DEEP", @"FIRE", @"MOON", @"SOUTH", @"ISLAND", @"PROBLEM", @"FOOT", @"PIECE", @"YET", @"TOLD", @"BUSY", @"KNEW", @"TEST", @"PASS", @"RECORD", @"FARM", @"BOAT", @"TOP", @"COMMON", @"WHOLE", @"GOLD", @"KING", @"POSSIBLE", @"SIZE", @"PLANE", @"HEARD", @"AGE", @"BEST", @"DRY", @"HOUR", @"WONDER", @"BETTER", @"LAUGH", @"TRUE .", @"THOUSAND", @"DURING", @"AGO", @"HUNDRED", @"RAN", @"AM", @"CHECK", @"REMEMBER", @"GAME", @"STEP", @"SHAPE", @"EARLY", @"YES", @"HOLD", @"HOT", @"WEST", @"MISS", @"GROUND", @"BROUGHT", @"INTEREST", @"HEAT", @"REACH", @"SNOW", @"FAST", @"BED", @"FIVE", @"BRING", @"SING", @"SIT", @"LISTEN", @"PERHAPS", @"SIX", @"FILL", @"TABLE", @"EAST", @"TRAVEL", @"WEIGHT", @"LESS", @"LANGUAGE", @"MORNING", @"AMONG", nil];
    
    NSString *name = @"oksiri.languagemodel";
    
    NSError *err = [lmGenerator generateLanguageModelFromArray:words withFilesNamed:name forAcousticModelAtPath:ACOUSTIC_MODEL_PATH];
    
    if([err code] == noErr)
    {
        
        self.languageGeneratorResults = lmGenerator;
    }
    else
    {
        NSLog(@"Error: %@",[err localizedDescription]);
    }
}

- (void)startRecognition
{
    NSLog(@"Starting OkSiri");
    
    if([self.pocketsphinxController isListening]) return;
    
    [self.pocketsphinxController setActive:TRUE error:nil];
    self.pocketsphinxController.audioMode = @"VoiceChat";
    
    NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"]];
    
    if (plist) { // Preference file exists
        NSString *pref = [plist objectForKey:@"keyword"];
        if (pref && [pref length] > 0) {
            if(![self.keyword isEqualToString:[pref uppercaseString]]) languageGeneratorResults = nil;
            self.keyword = [pref uppercaseString];
        }
        else self.keyword = DEFAULT_KEYWORD;
        
        pref = [plist objectForKey:@"sensitivity"];
        if (pref) {
            self.sensitivity = [pref intValue];
        }
        else self.sensitivity = DEFAULT_SENSITIVITY;
        
        pref = [plist objectForKey:@"activate"];
        if (pref) {
            if(![pref boolValue]) [self writeIfActivated:YES];
        }
    }
    else
    {
        self.keyword = DEFAULT_KEYWORD;
        self.sensitivity = DEFAULT_SENSITIVITY;
    }
    
    if(!self.statusBarItem)
    {
        self.statusBarItem =  [[NSClassFromString(@"LSStatusBarItem") alloc] initWithIdentifier: @"jzplusplus.OkSiri" alignment: StatusBarAlignmentRight];
        self.statusBarItem.imageName = @"oksiri";
        self.statusBarItem.visible = NO;
    }
    
//    NSError *activationError = nil;
//    BOOL success = [[AVAudioSession sharedInstance] setActive: YES error: &activationError];
//    
//    if (!success) {
//        NSLog(@"Audio Session Error");
//    }
    
    if(self.languageGeneratorResults == nil) [self generateLanguageModel];

    NSString *lmPath = [languageGeneratorResults pathToSuccessfullyGeneratedLanguageModelWithRequestedName:@"oksiri.languagemodel"];
    NSString *dicPath = [languageGeneratorResults pathToSuccessfullyGeneratedDictionaryWithRequestedName:@"oksiri.languagemodel"];
    
    [self.openEarsEventsObserver setDelegate:self];
    
    //[self.pocketsphinxController setAudioMode:@"VoiceChat"];
    //[self.pocketsphinxController setAudioSessionMixing:YES];
    //[self.pocketsphinxController setOutputAudio:NO];
    self.pocketsphinxController.secondsOfSilenceToDetect = 0.3;
    [self.pocketsphinxController setSecondsOfSilence];
    
    [self.pocketsphinxController startListeningWithLanguageModelAtPath:lmPath dictionaryAtPath:dicPath acousticModelAtPath:ACOUSTIC_MODEL_PATH languageModelIsJSGF:NO];
}

- (void)stopRecognition
{
    [self stopRecognitionTemporarily];
    [self writeIfActivated:NO];
}

- (void)stopRecognitionTemporarily
{
    NSLog(@"Stopping OkSiri");
    if(self.statusBarItem) self.statusBarItem.visible = NO;
    if([self.pocketsphinxController isListening]) [self.pocketsphinxController stopListening];
    
//    [self performSelector:@selector(reconfigureAudio) withObject:nil afterDelay: 1.0];
}

//- (void)reconfigureAudio
//{
//    NSError *setCategoryError = nil;
//    BOOL success = [[AVAudioSession sharedInstance]
//                    setCategory: AVAudioSessionCategoryAmbient
//                    error: &setCategoryError];
//    
//    if (!success) {
//        NSLog(@"Audio Session Error");
//    }
//    NSLog(@"Audio Session Reconfigured");
//    
//}

- (NSString *)localizedGroupForEventName:(NSString *)eventName {
    return @"OkSiri";
}

- (NSString *)localizedTitleForEventName:(NSString *)eventName {
    return [NSString stringWithFormat:@"Heard keyword: \"%@\"", self.keyword];
}

- (NSString *)localizedDescriptionForEventName:(NSString *)eventName {
    return @"OkSiri detected your chosen keyword";
}

+ (void)load
{
	@autoreleasepool
	{
        ok = [self new];
        [ok stopRecognition];
        ok.languageGeneratorResults = nil;
        ok.keyword = nil;
        
        dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
        _LAActivator = objc_getClass("LAActivator");
        if(_LAActivator)
        {
            _LAEvent = objc_getClass("LAEvent");
            [[_LAActivator sharedInstance] registerEventDataSource:ok forEventName:@"jzplusplus.OkSiri.keyword"];
        }
        
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)prefChanged, CFSTR("jzplusplus.oksiri/activate"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        
        NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Preferences/jzplusplus.OkSiri.plist"]];
        
        if (plist) { // Preference file exists
            NSNumber *pref = [plist objectForKey:@"afterrespring"];
            if (pref && [pref boolValue]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    NSLog(@"STARTING OKSIRI AFTER RESPRING");
                    [ok startRecognition];
                });
            }
        }
        
        _SBAssistantController = NSClassFromString(@"SBAssistantController");
        _VSSpeechSynthesizer = objc_getClass("VSSpeechSynthesizer");
        
        _VolumeControl = objc_getClass("VolumeControl");
        
        Class _SBMediaController = objc_getClass("SBMediaController");
        MSHookMessageEx(_SBMediaController, @selector(_nowPlayingInfoChanged), (IMP)&new_nowPlayingInfoChanged, (IMP*)&old_nowPlayingInfoChanged);
        
        Class _SBApplication = objc_getClass("SBApplication");
        MSHookMessageEx(_SBApplication, @selector(willActivate), (IMP)&new_willActivate, (IMP*)&old_willActivate);
        MSHookMessageEx(_SBApplication, @selector(didSuspend), (IMP)&new_didSuspend, (IMP*)&old_didSuspend);
	}
}

- (void) activateSiri
{
    NSLog(@"Activating Siri");
    if ([_SBAssistantController supportedAndEnabled] && [_SBAssistantController shouldEnterAssistant])
    {
        [[_SBAssistantController sharedInstance] activatePluginForEvent:0 eventSource:0 context:0];
        
        [self checkIfSiriStartedTalking];
    }
    
}

//This is a terrible hack and I feel bad for writing it
- (void) checkIfSiriStartedTalking
{
    //If Siri is gone, then stop this whole mess
    if(![_SBAssistantController isAssistantVisible]) return;
    
    //otherwise, wait until she starts talking before checking when she stops
    if(![_VSSpeechSynthesizer isSystemSpeaking])
    {
        [self performSelector:@selector(checkIfSiriStartedTalking) withObject:self afterDelay:0.25];
    }
    else
    {
        [self checkIfSiriFinishedTalking];
    }
}

- (void) checkIfSiriFinishedTalking
{
    //If Siri is gone, then stop this whole mess
    if(![_SBAssistantController isAssistantVisible]) return;
    
    //otherwise, wait until she stops talking so we can trigger again to make her listen
    if([_VSSpeechSynthesizer isSystemSpeaking])
    {
        [self performSelector:@selector(checkIfSiriFinishedTalking) withObject:self afterDelay:0.5];
    }
    else
    {
        [self performSelector:@selector(retriggerSiriIfActive) withObject:self afterDelay:1];
    }
}

- (void) retriggerSiriIfActive
{
    //If Siri is gone, then stop this whole mess
    if(![_SBAssistantController isAssistantVisible]) return;
    
    //otherwise, trigger again so we can continue talking
    [self activateSiri];
}

- (void) pocketsphinxDidReceiveHypothesis:(NSString *)hypothesis recognitionScore:(NSString *)recognitionScore utteranceID:(NSString *)utteranceID {
	NSLog(@"The received hypothesis is %@ with a score of %@ and an ID of %@", hypothesis, recognitionScore, utteranceID);
    
    int scoreThreshold = self.sensitivity - 10000;
    if([hypothesis isEqualToString:self.keyword] && [recognitionScore intValue] > scoreThreshold)
    {
        if(_LAActivator)
        {
            NSArray *listeners = [[_LAActivator sharedInstance] assignedListenerNamesForEvent:[_LAEvent eventWithName:@"jzplusplus.OkSiri.keyword" mode:[[_LAActivator sharedInstance] currentEventMode]]];
        
            if(listeners.count != 0 &&
               //if the only listener is Siri, we'll use our own method
               !(listeners.count == 1 && [listeners[0] isEqualToString:@"libactivator.system.virtual-assistant"])
               )
            {
                [[_LAActivator sharedInstance] sendEventToListener:[_LAEvent eventWithName:@"jzplusplus.OkSiri.keyword" mode:[[_LAActivator sharedInstance] currentEventMode]]];
                return;
            }
        }
        
        [self activateSiri];
    }
}


- (void) pocketsphinxDidStartListening {
	NSLog(@"Pocketsphinx is now listening.");
    self.statusBarItem.visible = YES;
}

- (void) pocketsphinxDidDetectSpeech {
	NSLog(@"Pocketsphinx has detected speech.");
}

- (void) pocketsphinxDidDetectFinishedSpeech {
	NSLog(@"Pocketsphinx has detected a period of silence, concluding an utterance.");
}

- (void) pocketsphinxDidStopListening {
	NSLog(@"Pocketsphinx has stopped listening.");
}

- (void) pocketsphinxDidSuspendRecognition {
	NSLog(@"Pocketsphinx has suspended recognition.");
}

- (void) pocketsphinxDidResumeRecognition {
	NSLog(@"Pocketsphinx has resumed recognition.");
}

- (void) pocketsphinxDidChangeLanguageModelToFile:(NSString *)newLanguageModelPathAsString andDictionary:(NSString *)newDictionaryPathAsString {
	NSLog(@"Pocketsphinx is now using the following language model: \n%@ and the following dictionary: %@",newLanguageModelPathAsString,newDictionaryPathAsString);
}

- (void) pocketSphinxContinuousSetupDidFailWithReason:(NSString *)reasonForFailure { 	NSLog(@"Setting up the continuous recognition loop has failed for the following reason:");
    NSLog(@"%@", reasonForFailure);
    
    [self performSelector:@selector(startRecognition) withObject:self afterDelay:2];
}

- (void) pocketSphinxContinuousTeardownDidFailWithReason:(NSString *)reasonForFailure { 	NSLog(@"Tearing down the continuous recognition loop has failed for the following reason:");
    NSLog(@"%@", reasonForFailure);
}

- (void) testRecognitionCompleted {
	NSLog(@"A test file that was submitted for recognition is now complete.");
}

- (void) pocketsphinxFailedNoMicPermissions {
    NSLog(@"Pocketsphinx failed because of mic permissions.");
}

- (void) audioSessionInterruptionDidBegin {
    NSLog(@"Pocketsphinx interrupted");
    
    //Have to stop when there's an interruption so we can reload when it's done
    [self stopRecognitionTemporarily];
}

- (void) audioSessionInterruptionDidEnd {
    NSLog(@"Pocketsphinx interruption ended");
    
    [self startRecognition];
}

- (void) audioInputDidBecomeUnavailable {
    NSLog(@"Pocketsphinx lost access to the microphone");
    
    [self stopRecognition];
}

- (void) audioInputDidBecomeAvailable {
    NSLog(@"Pocketsphinx gained access to the microphone");
}

- (void) audioRouteDidChangeToRoute:(NSString *)newRoute {
    NSLog(@"Pocketsphinx audio route changed to %@", newRoute);
}

@end
