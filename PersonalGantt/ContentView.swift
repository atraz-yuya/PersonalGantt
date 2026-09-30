//
//  ContentView.swift
//  PersonalGantt
//
//  Created by UserName on 2026/09/27.
//

import SwiftUI

struct Task :Identifiable{
    let id=UUID()
    var title :String
    var isCompleted:Bool
    var estimatedMinutes:Int
    var deadline :Date
}
struct ScheduledBlock:Identifiable{
    let id=UUID()
    var taskID:UUID
    var start:Date
    var end : Date
}
struct AvailableSlot{
    var start:Date
    var end: Date
}

struct ContentView:View {
    @State private var tasks:[Task]=[
        Task(title: "卒論",
             isCompleted:false,
             estimatedMinutes: 90,
             deadline:Calendar.current.date(from:DateComponents(year:2026,month: 9,day:30,hour:18))!),
        Task(title: "Atcoder", isCompleted:false,estimatedMinutes:120,
             deadline:Calendar.current.date(from:DateComponents(year:2026,month: 10,day:2,hour:3))!),
        Task(title: "Kaggle", isCompleted:false,
             estimatedMinutes:150,
             deadline:Calendar.current.date(from:DateComponents(year:2026,month: 10,day:1,hour:10))!)
    ]
    
    let availableSlots :[AvailableSlot]=[
        AvailableSlot(
            start: Calendar.current.date(from: DateComponents(
                year :2026,
                month : 9,
                day:28,
                hour :18
            ))!,
            end:Calendar.current.date(from: DateComponents(
                year:2026,
                month :9,
                day:28,
                hour :20
            )
            )!
        )
    ]
   
    var body: some View {
        return VStack(alignment: .leading){
            ForEach(tasks.sorted{
                $0.deadline<$1.deadline
            }) { task in
                let endTime = Calendar.current.date(
                    byAdding: .minute,
                    value: task.estimatedMinutes,
                    to:availableSlots[0].start
                )!
                let block=ScheduledBlock(
                    taskID: task.id,
                    start: availableSlots[0].start,
                    end:endTime
                )
                HStack{
                    Text(task.title)
                    
                    Text("\(task.estimatedMinutes)分")
                    Text(block.start, style: .time)
                    Text(block.end, style: .time)
                }
            }
        }
    }
}
#Preview {
    ContentView()
}
