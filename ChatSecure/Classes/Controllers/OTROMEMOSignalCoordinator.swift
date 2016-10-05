//
//  OTROMEMOSignalCoordinator.swift
//  ChatSecure
//
//  Created by David Chiles on 8/4/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import XMPPFramework
import YapDatabase

/** 
 * This is the glue between XMPP/OMEMO and Signal
 */
@objc public class OTROMEMOSignalCoordinator: NSObject {
    
    public let signalEncryptionManager:OTRAccountSignalEncryptionManager
    public let omemoStorageManager:OTROMEMOStorageManager
    public let accountYapKey:String
    public let databaseConnection:YapDatabaseConnection
    public weak var omemoModule:OMEMOModule?
    public weak var omemoModuleQueue:dispatch_queue_t?
    public var callbackQueue:dispatch_queue_t
    private let workQueue:dispatch_queue_t
    private var myJID:XMPPJID? {
        get {
            return omemoModule?.xmppStream.myJID
        }
    }
    let preKeyCount:UInt = 100
    private var outstandingDeviceBundleRequests:[String: (Bool) -> Void]
    /**
     Create a OTROMEMOSignalCoordinator for an account. 
     
     - parameter accountYapKey: The accounts unique yap key
     - parameter databaseConnection: A yap database connection on which all operations will be completed on
 `  */
    @objc public required init(accountYapKey:String,  databaseConnection:YapDatabaseConnection) throws {
        try self.signalEncryptionManager = OTRAccountSignalEncryptionManager(accountKey: accountYapKey,databaseConnection: databaseConnection)
        self.omemoStorageManager = OTROMEMOStorageManager(accountKey: accountYapKey, accountCollection: OTRAccount.collection(), databaseConnection: databaseConnection)
        self.accountYapKey = accountYapKey
        self.databaseConnection = databaseConnection
        self.outstandingDeviceBundleRequests = [:]
        self.callbackQueue = dispatch_queue_create("OTROMEMOSignalCoordinator-callback", DISPATCH_QUEUE_SERIAL)
        self.workQueue = dispatch_queue_create("OTROMEMOSignalCoordinator-work", DISPATCH_QUEUE_SERIAL)
    }
    
    /**
     Checks that a jid matches our own JID using XMPPJIDCompareBare
     */
    private func isOurJID(jid:XMPPJID) -> Bool {
        guard let ourJID = self.myJID else {
            return false;
        }
        
        return jid.isEqualToJID(ourJID, options: XMPPJIDCompareBare)
    }
    
    /** Always call on internal work queue*/
    private func callAndRemoveOutstandingBundleBlock(elementId:String,success:Bool) {
        
        guard let outstandingBlock = self.outstandingDeviceBundleRequests[elementId] else {
            return
        }
        outstandingBlock(success)
        self.outstandingDeviceBundleRequests.removeValueForKey(elementId)
    }
    
    /**
     Check if a buddy supports OMEMO. This checks if we've seen devices for this buddy.
     
     - parameter buddyYapKey: The yap key of the buddy.
     
     - returns: True if there are devices and the buddy supports OMEMO otherwise false.
     */
    public func buddySupportsOMEMO(buddyYapKey:String) -> Bool {
        return self.omemoStorageManager.getDevicesForParentYapKey(buddyYapKey, yapCollection: OTRBuddy.collection()).count > 0
    }
    
    /** 
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter buddyYapKey: The yap key for the buddy to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
    public func prepareSessionWithBuddy(buddyYapKey:String, completion:(Bool) -> Void) {
        var devices:[OTROMEMODevice]? = nil
        var username:String? = nil
        
        //Get all the devices ID's for this buddy as well as their username for use with signal and XMPPFramework.
        self.databaseConnection.readWithBlock { (transaction) in
            let dev = self.omemoStorageManager.getDevicesForParentYapKey(buddyYapKey, yapCollection: OTRBuddy.collection(),transaction: transaction)
            if (dev.count == 0) {
                //No devices so we can't go any further.
                dispatch_async(self.callbackQueue, { 
                    completion(false)
                })
                return
            }
            devices = dev
            username = OTRBuddy.fetchObjectWithUniqueID(buddyYapKey, transaction: transaction)?.username
        }
        
        guard let devs = devices, let buddyUsername = username else {
            dispatch_async(self.callbackQueue, {
                completion(false)
            })
            return
        }
        var finalSuccess = true
        dispatch_async(self.workQueue) { 
            let group = dispatch_group_create()
            //For each device Check if we have a session. If not then we need to fetch it from their XMPP server.
            for device in devs {
                if !self.signalEncryptionManager.sessionRecordExistsForUsername(buddyUsername, deviceId: device.deviceId.intValue) {
                    //No session for this buddy and device combo. We need to fetch the bundle.
                    
                    let elementId = NSUUID().UUIDString
                    
                    dispatch_group_enter(group)
                    // Hold on to a closure so that when we get the call back from OMEMOModule we can call this closure.
                    self.outstandingDeviceBundleRequests[elementId] = { success in
                        if (!success) {
                            finalSuccess = false
                        }
                        
                        dispatch_group_leave(group)
                    }
                    //Fetch the bundle
                    self.omemoModule?.fetchBundleForDeviceId(device.deviceId.unsignedIntValue, jid: XMPPJID.jidWithString(buddyUsername), elementId: elementId)
                }
            }
            
            dispatch_group_notify(group, self.callbackQueue) {
                completion(finalSuccess)
            }
        }
    }
}

extension OTROMEMOSignalCoordinator: OMEMOModuleDelegate {
    
    public func omemo(omemo: OMEMOModule, publishedDeviceIds deviceIds: [NSNumber], responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //print("publishedDeviceIds: \(responseIq)")
    }
    
    public func omemo(omemo: OMEMOModule, failedToPublishDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        //print("failedToPublishDeviceIds: \(errorIq)")
    }
    
    public func omemo(omemo: OMEMOModule, deviceListUpdate deviceIds: [NSNumber], fromJID: XMPPJID, incomingElement: DDXMLElement) {
        //print("deviceListUpdate: \(fromJID) \(deviceIds)")
    }
    
    public func omemo(omemo: OMEMOModule, failedToFetchDeviceIdsForJID fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        
    }
    
    public func omemo(omemo: OMEMOModule, publishedBundle bundle: OMEMOBundle, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //print("publishedBundle: \(responseIq) \(outgoingIq)")
    }
    
    public func omemo(omemo: OMEMOModule, failedToPublishBundle bundle: OMEMOBundle, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        //print("failedToPublishBundle: \(errorIq) \(outgoingIq)")
    }
    
    public func omemo(omemo: OMEMOModule, fetchedBundle bundle: OMEMOBundle, fromJID: XMPPJID, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        
        if (self.isOurJID(fromJID)) {
            //We fetched our own bundle?
            return;
        }
        
        dispatch_async(self.workQueue) {
            
            //Create incoming bundle from OMEMOBundle
            let innerBundle = OTROMEMOBundle(deviceId: bundle.deviceId, publicIdentityKey: bundle.identityKey, signedPublicPreKey: bundle.signedPreKey.publicKey, signedPreKeyId: bundle.signedPreKey.preKeyId, signedPreKeySignature: bundle.signedPreKey.signature)
            //Select random pre key to use
            let index = Int(arc4random_uniform(UInt32(bundle.preKeys.count)))
            let preKey = bundle.preKeys[index]
            let incomingBundle = OTROMEMOBundleIncoming(bundle: innerBundle, preKeyId: preKey.preKeyId, preKeyData: preKey.publicKey)
            //Consume the incoming bundle. This goes through signal and should hit the storage delegate. So we don't need to store ourselves here.
            self.signalEncryptionManager.consumeIncomingBundle(fromJID.bare(), bundle: incomingBundle)
            let elementId = outgoingIq.elementID()
            self.callAndRemoveOutstandingBundleBlock(elementId, success: true)
        }
        
    }
    public func omemo(omemo: OMEMOModule, failedToFetchBundleForDeviceId deviceId: gl_uint32_t, fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        
        dispatch_async(self.workQueue) {
            let elementId = outgoingIq.elementID()
            self.callAndRemoveOutstandingBundleBlock(elementId, success: false)
        }
        
    }
    
    public func omemo(omemo: OMEMOModule, receivedKeyData keyData: [NSNumber : NSData], iv: NSData, senderDeviceId: gl_uint32_t, fromJID: XMPPJID, payload: NSData?, message: XMPPMessage) {
        let rid = NSNumber(unsignedInt: self.signalEncryptionManager.registrationId)
        
        guard let ourEncryptedKeyData = keyData[rid], let encryptedPayload = payload else {
            return
        }
        do {
            let unencryptedKeyData = try self.signalEncryptionManager.decryptFromAddress(ourEncryptedKeyData, name: fromJID.bare(), deviceId: senderDeviceId)
            guard let messageBody = try OTRSignalEncryptionHelper.decryptData(encryptedPayload, key: unencryptedKeyData, iv: iv) else {
                return
            }
            let messageString = String(data: messageBody, encoding: NSUTF8StringEncoding)
            self.databaseConnection.readWriteWithBlock({ (transaction) in
                // TODO: check if it's our jid and handle as an outgoing message from another device
                guard let buddy = OTRBuddy.fetchBuddyWithUsername(fromJID.bare(), withAccountUniqueId: self.accountYapKey, transaction: transaction) else {
                    return
                }
                let databaseMessage = OTRMessage()
                databaseMessage.incoming = true
                databaseMessage.text = messageString
                databaseMessage.buddyUniqueId = buddy.uniqueId
                databaseMessage.transportedSecurely = true
                databaseMessage.messageId = message.elementID()
                
                databaseMessage.saveWithTransaction(transaction)
            })
        } catch {
            return
        }
        
    }
}

extension OTROMEMOSignalCoordinator:OMEMOStorageDelegate {
    
    public func configureWithParent(aParent: OMEMOModule, queue: dispatch_queue_t) -> Bool {
        self.omemoModule = aParent
        self.omemoModuleQueue = queue
        return true
    }
    
    public func storeDeviceIds(deviceIds: [NSNumber], forJID jid: XMPPJID) {
        
        let isOurDeviceList = self.isOurJID(jid)
        
        if (isOurDeviceList) {
            self.omemoStorageManager.storeOurDevices(deviceIds)
        } else {
            self.omemoStorageManager.storeBuddyDevices(deviceIds, buddyUsername: jid.bare())
        }
    }
    
    public func fetchDeviceIdsForJID(jid: XMPPJID) -> [NSNumber] {
        var devices:[OTROMEMODevice]?
        if self.isOurJID(jid) {
            devices = self.omemoStorageManager.getDevicesForOurAccount()
            
        } else {
            devices = self.omemoStorageManager.getDevicesForBuddy(jid.bare())
        }
        //Convert from devices array to NSNumber array.
        return (devices?.map({ (device) -> NSNumber in
            return device.deviceId
        })) ?? [NSNumber]()
        
    }

    //Always returns most complete bundle with correct count of prekeys
    public func fetchMyBundle() -> OMEMOBundle? {
        
        guard let bundle = self.signalEncryptionManager.storage.fetchOurExistingBundle() ?? self.signalEncryptionManager.generateOutgoingBundle(self.preKeyCount) else {
            return nil
        }
        
        var preKeys = bundle.preKeys
        
        let keysToGenerate = Int(self.preKeyCount) - preKeys.count
        
        //Check if we don't have all the prekeys we need
        if (keysToGenerate > 0) {
            var start:UInt = 0
            if let maxId = self.signalEncryptionManager.storage.currentMaxPreKeyId() {
                start = UInt(maxId) + 1
            }
            
            let newPreKeys = self.signalEncryptionManager.generatePreKeys(start, count: UInt(keysToGenerate))
            newPreKeys?.forEach({ (preKey) in
                preKeys.updateValue(preKey.keyPair().publicKey, forKey: preKey.preKeyId())
            })
        }
        
        var preKeysArray = [OMEMOPreKey]()
        preKeys.forEach { (id,data) in
            let omemoPreKey = OMEMOPreKey(preKeyId: id, publicKey: data)
            preKeysArray.append(omemoPreKey)
        }
        
        let omemoSignedPreKey = OMEMOSignedPreKey(preKeyId: bundle.bundle.signedPreKeyId, publicKey: bundle.bundle.signedPublicPreKey, signature: bundle.bundle.signedPreKeySignature)
        return OMEMOBundle(deviceId: bundle.bundle.deviceId, identityKey: bundle.bundle.publicIdentityKey, signedPreKey: omemoSignedPreKey, preKeys: preKeysArray)
    }

    public func isSessionValid(jid: XMPPJID, deviceId: gl_uint32_t) -> Bool {
        return self.signalEncryptionManager.sessionRecordExistsForUsername(jid.bare(), deviceId: Int32(deviceId))
    }
}
