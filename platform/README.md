---
type: overview
title: 平台層總覽
description: "Directory entry point for platform/: the boundary rule, and a pointer to the single capability index in the root README."
tags:
  - platform
  - entry-point
timestamp: 2026-09-02T00:00:00+08:00
---

# Platform 元件

## 各能力的說明在根 README，不在這裡

**能力索引只有一份**，在根目錄的 [`README.md`](../README.md) 第三節「各能力的說明在哪」，
那裡列出 `platform/` 每一個子目錄與它的 README。

這個檔案在 2026-09-02 之前是**第二份索引**，而且是過期的那份——它宣稱
「所有目前已知可本機自主完成的項目皆已完成，唯一剩餘項目是 Public URL」，
那句話寫於 2026-08-10，在 Kubernetes、第二台機器、跨架構映像守衛、
健康彙總、DAST 涵蓋率之前。

**兩份索引的問題不是重複，是分岔。** 沒有人會同時更新兩份，於是其中一份
開始說謊，而它讀起來和另一份一模一樣。這裡改成薄指標，就沒有第二份可以過期。

現況、看板網址、紀錄位置、能力清單，全部看根 README。

## 這個目錄的邊界規則（這一條只寫在這裡）

`platform/` 只放**可被多個 Pilot 共用**的 DevOps 元件，不放特定服務的業務程式。

Platform 的修改必須考慮所有 Pilot，**不得為了單一 Pilot 直接放寬共用安全門檻**。
需要放寬時，放寬的是那個 Pilot 自己的設定，不是平台的預設值——否則第二個 Pilot
會繼承一個為了第一個 Pilot 而降低的門檻，而且不會知道。

Pilot 端的對應說明見 [`pilots/README.md`](../pilots/README.md)。
