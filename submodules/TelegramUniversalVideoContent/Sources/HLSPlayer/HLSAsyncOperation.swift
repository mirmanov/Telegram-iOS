//
//  HLSAsyncOperation.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 24.10.2024.
//

import Foundation

class HLSAsyncOperation: Operation, @unchecked Sendable {
            
        @objc private enum OperationState: Int {
            case ready
            case executing
            case finished
        }
        
        private let stateQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! + ".hls-async-op.state", attributes: .concurrent)
        
        private var _state: OperationState = .ready
        
        @objc private dynamic var state: OperationState {
            get { return stateQueue.sync { _state } }
            set { stateQueue.async(flags: .barrier) { self._state = newValue } }
        }
        
        override var isReady: Bool { return state == .ready && super.isReady }
        final override var isExecuting: Bool { return state == .executing }
        final override var isFinished: Bool { return state == .finished }
        final override var isAsynchronous: Bool { return true }

        override class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String> {
            if ["isReady", "isFinished", "isExecuting"].contains(key) {
                return [#keyPath(state)]
            }
            
            return super.keyPathsForValuesAffectingValue(forKey: key)
        }
        
        final override func start() {
            if isCancelled {
                state = .finished
                return
            }
            
            state = .executing
            
            main()
        }
        
        override func main() {
            fatalError("Subclasses must implement `main`.")
        }
        
        final func finish() {
            if !isFinished { state = .finished }
        }
}
