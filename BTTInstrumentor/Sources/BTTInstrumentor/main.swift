//
//  main.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//


import Foundation

let args = BTTArgs.parse()
let runner = BTTRunner(args: args)
runner.run()
