//
//  main.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//


import Foundation

let args = BTTArgs.parse()
let command = BTTCommandRunner(args: args)
command.run()
