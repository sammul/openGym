#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Bridges the Swift WatchPlugin into Capacitor's Objective-C plugin registry.
CAP_PLUGIN(WatchPlugin, "Watch",
           CAP_PLUGIN_METHOD(sendPack, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(sendLive, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(status, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(drain, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(ack, CAPPluginReturnPromise);
)
