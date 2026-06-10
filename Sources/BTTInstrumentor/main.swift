//
//  main.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

let bttCommand = BTTCommandRunner(args: BTTArgs.parse())
bttCommand.run()
