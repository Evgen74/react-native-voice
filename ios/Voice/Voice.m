#import "Voice.h"
#import <React/RCTLog.h>
#import <UIKit/UIKit.h>
#import <React/RCTUtils.h>
#import <React/RCTEventEmitter.h>
#import <Speech/Speech.h>
#import <Accelerate/Accelerate.h>

@interface Voice () <SFSpeechRecognizerDelegate>

@property (nonatomic) SFSpeechRecognizer* speechRecognizer;
@property (nonatomic) SFSpeechAudioBufferRecognitionRequest* recognitionRequest;
@property (nonatomic) AVAudioEngine* audioEngine;
@property (nonatomic) SFSpeechRecognitionTask* recognitionTask;
@property (nonatomic) AVAudioSession* audioSession;
@property (nonatomic) double rate;
@property float averagePowerForChannel0;
@property float averagePowerForChannel1;
@property BOOL flag;
@end

@implementation Voice
{
}
- (id) init{

    self.rate = 0;
    return self;
}
- (void) setupAndStartRecognizing:(NSString*)localeStr {
    [self teardown];
    self.flag = true;
    NSLocale* locale = nil;
    if ([localeStr length] > 0) {
        locale = [NSLocale localeWithLocaleIdentifier:localeStr];
    }

    if (locale) {
        self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    } else {
        self.speechRecognizer = [[SFSpeechRecognizer alloc] init];
    }

    self.speechRecognizer.delegate = self;

    NSError* audioSessionError = nil;
    self.audioSession = [AVAudioSession sharedInstance];

    if (self.audioSession) {
        [self.audioSession setCategory:AVAudioSessionCategoryRecord error:nil];
        [self.audioSession setMode:AVAudioSessionModeMeasurement error:nil];
        [self.audioSession setActive:true withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }


    if (audioSessionError != nil) {
        [self sendResult:RCTMakeError([audioSessionError localizedDescription], nil, nil) :nil :nil :nil];
        self.flag=false;
        return;
    }

    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];

    if (self.recognitionRequest == nil){
        [self sendResult:RCTMakeError(@"Unable to created a SFSpeechAudioBufferRecognitionRequest object", nil, nil) :nil :nil :nil];
        self.flag=false;
        return;
    }

    if (self.audioEngine == nil) {
        self.audioEngine = [[AVAudioEngine alloc] init];
    }

    AVAudioInputNode* inputNode = self.audioEngine.inputNode;
    if (inputNode == nil) {
        [self sendResult:RCTMakeError(@"Audio engine has no input node", nil, nil) :nil :nil :nil];
        self.flag=false;
        return;
    }

    // Configure request so that results are returned before audio recording is finished
    self.recognitionRequest.shouldReportPartialResults = YES;



    // A recognition task represents a speech recognition session.
    // We keep a reference to the task so that it can be cancelled.
    self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
        if (error != nil) {
            NSString *errorMessage = [NSString stringWithFormat:@"%ld/%@", error.code, [error localizedDescription]];
            [self sendResult:RCTMakeError(errorMessage, nil, nil) :nil :nil :nil];
            [self teardown];
            self.flag=false;
            return;
        }

        BOOL isFinal = result.isFinal;
        if (result != nil) {
            NSMutableArray* transcriptionDics = [NSMutableArray new];
            for (SFTranscription* transcription in result.transcriptions) {
                [transcriptionDics addObject:transcription.formattedString];
            }
            [self sendResult:nil:result.bestTranscription.formattedString :transcriptionDics :@(isFinal)];
        }

        if (isFinal == YES) {
            if (self.recognitionTask.isCancelled || self.recognitionTask.isFinishing){
                [self sendEventWithName:@"onSpeechEnd" body:@{@"error": @false}];
            }
            [self teardown];
        }
    }];
    AVAudioMixerNode* tempNode = [[AVAudioMixerNode alloc] init];
    [self.audioEngine attachNode:tempNode];
    [self.audioEngine connect:inputNode to:tempNode format:nil];

    AVAudioFormat* recordingFormat = [inputNode inputFormatForBus:0];

    if(self.rate == 0){
        self.rate = [inputNode inputFormatForBus:0].sampleRate;
    }
    recordingFormat = [recordingFormat initStandardFormatWithSampleRate:self.rate channels:1];

    [tempNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {

        //===volume metering level====
        [buffer setFrameLength:1024];
        UInt32 inNumberFrames = buffer.frameLength;
        float LEVEL_LOWPASS_TRIG = 0.5;
        if(buffer.format.channelCount>0)
        {
            Float32* samples = (Float32*)buffer.floatChannelData[0];
            Float32 avgValue = 0;

            vDSP_meamgv((Float32*)samples, 1, &avgValue, inNumberFrames);
            self.averagePowerForChannel0 = (LEVEL_LOWPASS_TRIG*((avgValue==0)?-100:20.0*log10f(avgValue))) + ((1-LEVEL_LOWPASS_TRIG)*self.averagePowerForChannel0) ;
            self.averagePowerForChannel1 = self.averagePowerForChannel0;

        }

        if(buffer.format.channelCount>1)
        {
            Float32* samples = (Float32*)buffer.floatChannelData[1];
            Float32 avgValue = 0;

            vDSP_meamgv((Float32*)samples, 1, &avgValue, inNumberFrames);
            self.averagePowerForChannel1 = (LEVEL_LOWPASS_TRIG*((avgValue==0)?-100:20.0*log10f(avgValue))) + ((1-LEVEL_LOWPASS_TRIG)*self.averagePowerForChannel1) ;

        }
        NSLog(@"===test===%.2f", self.averagePowerForChannel1);
        //===end volume metering level====
        NSNumber *value = [NSNumber numberWithFloat:self.averagePowerForChannel1];
        [self sendEventWithName:@"onSpeechVolumeLevel" body:@{@"level": value}];

        if (self.recognitionRequest != nil) {
            [self.recognitionRequest appendAudioPCMBuffer:buffer];
        }
    }];

    [self.audioEngine prepare];
    [self.audioEngine startAndReturnError:&audioSessionError];
    if (audioSessionError != nil) {
        [self sendResult:RCTMakeError([audioSessionError localizedDescription], nil, nil) :nil :nil :nil];
        return;
    }
    NSNumber *key = [NSNumber numberWithBool:self.flag];
    [self sendEventWithName:@"onSpeechStart" body:@[key]];
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[
             @"onSpeechResults",
             @"onSpeechStart",
             @"onSpeechPartialResults",
             @"onSpeechError",
             @"onSpeechEnd",
             @"onSpeechRecognized",
             @"onSpeechVolumeChanged",
             @"onSpeechVolumeLevel",
             ];
}

- (void) sendResult:(NSDictionary*)error :(NSString*)bestTranscription :(NSArray*)transcriptions :(NSNumber*)isFinal {
    if(self.bridge){
        if (error != nil) {
            [self sendEventWithName:@"onSpeechError" body:@{@"error": error}];
        }
        if (bestTranscription != nil) {
            [self sendEventWithName:@"onSpeechResults" body:@{@"value":@[bestTranscription]} ];
        }
        if (transcriptions != nil) {
            [self sendEventWithName:@"onSpeechPartialResults" body:@{@"value":transcriptions} ];
        }
        if (isFinal != nil) {
            [self sendEventWithName:@"onSpeechRecognized" body: @{@"isFinal": isFinal}];
        }
    }
}

- (void) teardown {
    [self.recognitionTask cancel];
    self.recognitionTask = nil;
    self.audioSession = nil;

    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        [self.recognitionRequest endAudio];
        [self.audioEngine.inputNode removeTapOnBus:0];
    }

    self.recognitionRequest = nil;
    AVAudioSession *avAudioSession = [AVAudioSession sharedInstance];
    if (avAudioSession) {
        [avAudioSession setCategory:AVAudioSessionCategoryPlayback error:nil];
        [avAudioSession setMode:AVAudioSessionModeDefault error:nil];
    }
}

// Called when the availability of the given recognizer changes
- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    if (available == false) {
        [self sendResult:RCTMakeError(@"Speech recognition is not available now", nil, nil) :nil :nil :nil];
        NSNumber *key = [NSNumber numberWithBool:false];
        [self sendEventWithName:@"onSpeechStart" body:@[key]];
    }
}

RCT_EXPORT_METHOD(stopSpeech:(RCTResponseSenderBlock)callback)
{
    [self.recognitionTask finish];
    callback(@[@false]);
}


RCT_EXPORT_METHOD(cancelSpeech:(RCTResponseSenderBlock)callback) {
    [self.recognitionTask cancel];
    callback(@[@false]);
}

RCT_EXPORT_METHOD(destroySpeech:(RCTResponseSenderBlock)callback) {
    [self teardown];
    callback(@[@false]);
}

RCT_EXPORT_METHOD(isSpeechAvailable:(RCTResponseSenderBlock)callback) {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        switch (status) {
            case SFSpeechRecognizerAuthorizationStatusAuthorized:
                callback(@[@true]);
                break;
            default:
                callback(@[@false]);
        }
    }];
}
RCT_EXPORT_METHOD(isRecognizing:(RCTResponseSenderBlock)callback) {
    if (self.recognitionTask != nil){
        switch (self.recognitionTask.state) {
            case SFSpeechRecognitionTaskStateRunning:
                callback(@[@true]);
                break;
            default:
                callback(@[@false]);
        }
    }
    else {
        callback(@[@false]);
    }
}

RCT_EXPORT_METHOD(startSpeech:(NSString*)localeStr callback:(RCTResponseSenderBlock)callback) {
    if (self.recognitionTask != nil) {
        [self sendResult:RCTMakeError(@"Speech recognition already started!", nil, nil) :nil :nil :nil];
        NSNumber *key = [NSNumber numberWithBool:true];
        [self sendEventWithName:@"onSpeechStart" body:@[key]];
        return;
    }

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        switch (status) {
            case SFSpeechRecognizerAuthorizationStatusNotDetermined:
                [self sendResult:RCTMakeError(@"Speech recognition not yet authorized", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusDenied:
                [self sendResult:RCTMakeError(@"User denied access to speech recognition", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusRestricted:
                [self sendResult:RCTMakeError(@"Speech recognition restricted on this device", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusAuthorized:
                [self setupAndStartRecognizing:localeStr];
                break;
        }
    }];
    callback(@[@false]);
}


- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()



@end


