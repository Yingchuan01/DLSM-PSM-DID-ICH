*==========PSM安装==========*
ssc install psmatch2,replace
help psmatch2
ssc install rbounds,replace
search eststo


/*数据导入*/
import excel using "F:\桌面\PSM数据\PSM数据分析-数据整合表.xlsx", firstrow clear
 
 
/*基础指令*/
psmatch2 t age gender
pstest age gender, both


/*文化认同与再传播意愿问卷的综合得分*/
/*仅保留体验后样本（post==1）*/
keep if post == 1
/*1.生成文化认同综合得分 ci_score*/
local ciVars ///
    know_hist_orig_shadow      know_recog_symbols        know_cultural_signif ///
    know_explain_process       know_fam_folk_stories     pride_cultural_trad ///
    pride_deepen               pride_proud_others        pride_unimportant_rev ///
    pride_show_unique          conn_ancestors            conn_close_shadow ///
    conn_belonging             conn_resonance            conn_share_love ///
    behav_learn_craft          behav_operate_char        behav_attend_events ///
    behav_study_details        behav_engage_online       value_inspire ///
    value_family_friend        value_respect_multi       value_preserve_arts ///
    value_mix_trad_tech        social_tell_family        social_share_media ///
    social_encourage_try       social_incorporate        social_pass_nextgen

capture drop ci_score
egen ci_score = rowmean(`ciVars')               // 30 题平均=ci_score
summarize ci_score                              // 快速验算

/*仅保留体验后样本（post==1）*/
keep if post == 1
/*2.生成再传播意愿综合得分 rpi_score*/
/*3.重新定义rpiVars，只包含确实存在的变量*/
local rpiVars ///
    digital_recomm_exhib  digital_mention_ftf  digital_suggest_trip ///
    digital_priority_similar digital_encourage_hesit digital_plan_child_exp ///
    digital_recomm_friends digital_recomm_3times digital_record_video ///
    digital_use_patterns   digital_tell_story   digital_demo_moves ///
    digital_wear_items     digital_place_photos digital_encourage_draw ///
    digital_finance_support

capture drop rpi_score
egen rpi_score = rowmean(`rpiVars')             // 16 题平均 = rpi_score
summarize rpi_score                              // 快速验算


/*logit模型估计pscore*/
*文化认同（ci_score）
psmatch2 t age gender, logit outcome(ci_score)
*再传播意愿（rpi_score）
psmatch2 t age gender, logit outcome(rpi_score)


/*平衡性检验*/
pstest age gender, both graph


/*共 同 支 持 域 可 视 化
 - 核密度叠加图
 - 箱线图
 - psgraph内建图*/
/*1.核密度叠加图*/
twoway ///
    (kdensity _pscore if _treated==1, lp(solid)  lw(*2.5)) /// 实验组
    (kdensity _pscore if _treated==0, lp(dash)   lw(*2.5)), /// 控制组
    ///
    ytitle("核密度") ylabel(, angle(0)) ///
    xtitle("倾向得分 (_pscore)") xscale(titlegap(2)) ///
    xlabel(0(0.2)1, format(%2.1f)) ///
    legend(label(1 "实验组") label(2 "控制组") row(2) ///
           position(12) ring(0)) ///
    scheme(s1mono)
/*2.支持域内的箱线图*/
graph box _pscore if _support==1, by(_treated) ///
    ytitle("倾向得分 (_pscore)") ///
    legend(off) scheme(s1mono)
/*3.重叠检查*/
psgraph, support(_support)	
	

/*敏感性检验*/
*文化认同（ci_score）
rbounds ci_score,gamma(1(0.2)2 3(1) 5)
*再传播意愿（rpi_score）
rbounds rpi_score,gamma(1(0.2)2 3(1) 5)





================================================================================

/*******************************************************************
  PSM→并回→两期面板（pid×time）→平行趋势图→DID
  Stata 19 兼容；尽量写得自检/容错；可一段段执行
*******************************************************************/

version 19
set more off

* =============== 0. 路径与关键变量名（按需修改） ===============
* 两期总表（含前/后测），你的 Excel
global PANEL_XLS "F:\桌面\PSM数据\PSM数据分析-数据整合表.xlsx"

* 导出与中间文件存放目录
global OUTDIR    "F:\桌面\PSM数据"

* 面板里的"受访者主键"列名（面板表中的 id 列名，现有就是 id）
global IDVAR     "id"

* 面板里的时间变量：若已有 time=0/1 就写 time；若只有 post=0/1，则会自动生成 time
global TIMEVAR   "time"      // 若没有 time 只有 post，这里也写 time，下面会由 post 生出 time

* PSM 匹配后得到的变量（psmatch2 的默认产物）
* _treated, _support, _pscore, _weight
* ---------------------------------------------------------------


* =============== 1. 从当前 PSM 数据集导出"匹配名册" ===============
* 前提：此时内存里是你做完 PSM 的"后测样本"数据，且存在
*       id, _treated, _support, _pscore, _weight 等变量
preserve
    * ——【0】基本设置（按需修改路径/主键）——
version 19
set more off
global OUT "F:\桌面\PSM数据"
global IDVAR id

* ——【1】只保留共同支持域 + 匹配成功（权重>0）——
capture confirm variable _support
assert !_rc  // 没有 _support 就会停
keep if _support==1

* 允许重复执行：无论当前权重变量叫 _weight 还是 aw_weight 都统一过滤
capture confirm variable aw_weight
if !_rc {
    gen double __w = aw_weight
}
else {
    capture confirm variable _weight
    assert !_rc
    gen double __w = _weight
}
drop if missing(__w) | __w<=0

* ——【2】只留关键变量——
keep ${IDVAR} _treated _pscore _support __w

* ——【3】构造字符串主键 id_key（统一大小写/去空格；原 id 数值也能兼容）——
capture drop id_key
capture confirm string variable ${IDVAR}
if !_rc {
    gen strL id_key = upper(trim(${IDVAR}))
}
else {
    tostring ${IDVAR}, gen(__idstr) format(%20.0g)
    replace __idstr = upper(trim(__idstr))
    gen strL id_key = __idstr
    drop __idstr
}

* ——【4】把权重重命名为 aw_weight（期刊友好）——
rename __w aw_weight
label var aw_weight "PSM analytic weight (aweight)"

* ——【5】自检（必须全部通过）——
count if missing(aw_weight) | aw_weight<=0
count if missing(_treated) | !inlist(_treated,0,1)
count if missing(id_key)

assert !missing(id_key) & inlist(_treated,0,1) & aw_weight>0

*——保存路径（按你电脑改一次即可）——*
local ROOT "F:\桌面\PSM数据"

* 这里的数据里应包含：id_key（你刚刚做好的主键）、_treated、_pscore、_support、aw_weight
* 再做一个稳妥的自检（你刚才已通过，这里只是保险）
count if missing(aw_weight) | aw_weight<=0
count if missing(_treated)  | !inlist(_treated,0,1)
count if missing(id_key)
assert !missing(id_key) & inlist(_treated,0,1) & aw_weight>0

* 保存"匹配名单"（供并回两期面板）
keep id_key _treated _pscore _support aw_weight
isid id_key, sort
save "`ROOT'\matched_roster_key.dta", replace

* =============== 2. PSM数据载入"两期面板"并标准化 id/time ===============
*—— 打开你的"前测+后测"两期总表 ——*
clear
import excel using "F:\桌面\PSM数据\PSM数据分析-数据整合表.xlsx", firstrow clear

*—— 统一主键：生成与名单一致的 id_key（大写+去前后空格）——*
capture drop id_key
capture confirm string variable id
if !_rc {
    gen strL id_key = upper(trim(id))
}
else {
    * 若 id 已是数值，临时转成字符串再统一格式
    tostring id, gen(id_str) force
    replace  id_str = upper(trim(id_str))
    gen strL id_key = id_str
    drop id_str
}
label var id_key "string key (统一大写去空格)"

*—— 构造 time=0/1（若已存在 time 可跳过）——*
capture confirm variable time
if _rc {
    capture confirm variable post
    if !_rc {
        gen byte time = post
        label define TIME 0 "Pre" 1 "Post"
        label values time TIME
    }
    else {
        di as err "没找到 time 或 post。若你的表是 *_pre / *_post 结构，需要 reshape。"
        error 111
    }
}

*—— 只保留合法两期：0/1 ——*
keep if inlist(time,0,1)
assert inlist(time,0,1) & !missing(time)

*==================== 修复 id_key 类型 & 合并 ====================*

* 0) 路径（和你前面 A 步一致）
local ROOT "F:\桌面\PSM数据"

* 1) 当前内存里是"前测+后测"的两期面板（你已经 import excel 了）
*    若还没加载，取消下一行注释，改成你的 Excel 路径
* import excel using "F:\桌面\PSM数据\PSM数据分析-数据整合表-数据整合表.xlsx", firstrow clear

* 2) 统一把当前数据的 id_key 从 strL 转成定长字符串（顺便大写&去空格）
capture confirm strL variable id_key
if !_rc {
    gen str80 __idtmp = upper(strtrim(id_key))
    drop id_key
    rename __idtmp id_key
}
label var id_key "string key (统一大写去空格)"

* 3) 也把"PSM 名册"里的 id_key 统一成定长字符串，避免两边类型不一致
preserve
    use "`ROOT'\matched_roster_key.dta", clear
    capture confirm strL variable id_key
    if !_rc {
        gen str80 __idtmp = upper(strtrim(id_key))
        drop id_key
        rename __idtmp id_key
    }
    isid id_key, sort
    save "`ROOT'\matched_roster_key.dta", replace
restore

* 4) 只保留合法两期（你前面已做，这里再保险一次）
keep if inlist(time,0,1)
assert inlist(time,0,1) & !missing(time)

* 5) 合并（只保留 match）
merge m:1 id_key using "`ROOT'\matched_roster_key.dta", keep(match) nogen

* 6) 快速自检：这三项必须都在、且权重大于 0
assert !missing(id_key) & inlist(_treated,0,1) & aw_weight>0


*—— 严格留在共同支持域、且 aw_weight>0 ——*
keep if _support==1
drop if missing(aw_weight) | aw_weight<=0

*—— 生成数值面板 id（pid），声明面板 ——*
egen pid = group(id_key), label
xtset pid time


* =============== 3. 可视化平行趋势（两期 = 看均值折线） ===============

*—— 若没有就生成 ci_score / rpi_score（在两期面板上）——*
capture confirm variable ci_score
if _rc {
    * 30 个文化认同条目（你之前用过的那一串）
    local ciVars ///
        know_hist_orig_shadow  know_recog_symbols    know_cultural_signif ///
        know_explain_process   know_fam_folk_stories pride_cultural_trad ///
        pride_deepen           pride_proud_others    pride_unimportant_rev ///
        pride_show_unique      conn_ancestors        conn_close_shadow ///
        conn_belonging         conn_resonance        conn_share_love ///
        behav_learn_craft      behav_operate_char    behav_attend_events ///
        behav_study_details    behav_engage_online   value_inspire ///
        value_family_friend    value_respect_multi   value_preserve_arts ///
        value_mix_trad_tech    social_tell_family    social_share_media ///
        social_encourage_try   social_incorporate    social_pass_nextgen

    egen ci_score = rowmean(`ciVars')  if inlist(time,0,1)
    label var ci_score "Cultural identity composite score"
}

capture confirm variable rpi_score
if _rc {
    * 16 个再传播意愿条目（你之前用过的那一串）
    local rpiVars ///
        digital_recomm_exhib   digital_mention_ftf    digital_suggest_trip ///
        digital_priority_similar digital_encourage_hesit digital_plan_child_exp ///
        digital_recomm_friends digital_recomm_3times  digital_record_video ///
        digital_use_patterns   digital_tell_story     digital_demo_moves ///
        digital_wear_items     digital_place_photos   digital_encourage_draw ///
        digital_finance_support

    egen rpi_score = rowmean(`rpiVars') if inlist(time,0,1)
    label var rpi_score "Repropagation intention composite score"
}

* 快速核查一下确实生成了
ds ci_score rpi_score
summ ci_score rpi_score if inlist(time,0,1)

*—— 平行趋势均值折线 ——*
preserve
collapse (mean) ci_m=ci_score rpi_m=rpi_score [aw=aw_weight], by(_treated time)

twoway (connected ci_m  time if _treated==1, msymbol(o) lpattern(solid)) ///
       (connected ci_m  time if _treated==0, msymbol(t) lpattern(dash)), ///
       xtitle("Wave (0=Pre, 1=Post)") ytitle("Mean CI score") ///
       legend(order(1 "Treated" 2 "Control")) name(ci_trend, replace)

twoway (connected rpi_m time if _treated==1, msymbol(o) lpattern(solid)) ///
       (connected rpi_m time if _treated==0, msymbol(t) lpattern(dash)), ///
       xtitle("Wave (0=Pre, 1=Post)") ytitle("Mean RPI score") ///
       legend(order(1 "Treated" 2 "Control")) name(rpi_trend, replace)
restore



* =============== 5. DID 因果分析 ===============
/* ===== D）DID 因果分析（最小规范） =====
   需要：pid、time(0/1)、_treated(0/1)、aw_weight、ci_score、rpi_score
*/

* 基本自检（简短）
assert inlist(time,0,1) & !missing(pid)
assert !missing(_treated) & inlist(_treated,0,1)
assert !missing(aw_weight)


* —— CI 结局的 DID（个体固定效应 + 聚类稳健标准误）——
xtreg ci_score i.time##i._treated [aw=aw_weight], fe vce(cluster pid)
lincom 1.time#1._treated    // DID 净效应：Post×Treated

* —— RPI 结局的 DID（个体固定效应 + 聚类稳健标准误）——
xtreg rpi_score i.time##i._treated [aw=aw_weight], fe vce(cluster pid)
lincom 1.time#1._treated    // DID 净效应：Post×Treated



























