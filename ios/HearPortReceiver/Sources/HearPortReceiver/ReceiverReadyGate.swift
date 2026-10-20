struct ReceiverReadyGate {
    var receiverReadyWritten = false
    var audioStreamAcknowledged = false
    private var notified = false

    mutating func takeNotification(networkProbe: Bool) -> Bool {
        guard receiverReadyWritten, networkProbe || audioStreamAcknowledged, !notified else { return false }
        notified = true
        return true
    }
}
