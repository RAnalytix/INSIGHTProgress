################################################################################
## Data management to create MOSAIC study progress dashboard
################################################################################

library(httr)
library(tidyverse)
library(stringr)
library(lubridate)

## -- Import each data set from REDCap (exclusions, in-hospital, follow-up) ----
## All tokens are stored in .Renviron

## We'll be doing the same thing for each, so write some functions
## 1. Function to create postForm() object given a database token
get_pF <- function(rctoken){
  httr::POST(
    url = "https://redcap.vanderbilt.edu/api/",
    body = list(
      token = Sys.getenv(rctoken),   ## API token gives you permission
      content = "record",            ## export *records*
      format = "csv",                ## export as *CSV*
      rawOrLabel = "label",          ## export factor *labels* v codes
      exportCheckboxLabel = TRUE,    ## exp. checkbox labels vs U/C
      exportDataAccessGroups = FALSE ## don't need data access grps
    )
  )
}

get_csv <- function(pF){
  read.csv(text = as.character(pF), na.strings = "", stringsAsFactors = FALSE)
}

import_df <- function(rctoken){
  tmp_pF <- get_pF(rctoken)
  tmp_csv <- get_csv(tmp_pF)

  ## REDCap loves to use so many underscores; one per instance seems like plenty
  names(tmp_csv) <- gsub("_+", "_", names(tmp_csv))

  tmp_csv
}

## Comment out while building dashboard to save time
inhosp_df <- import_df("INSIGHT_IH_TOKEN")
exc_df <- import_df("INSIGHT_EXC_TOKEN")
fu_df <- import_df("INSIGHT_FU_TOKEN")
# save(inhosp_df, exc_df, fu_df, file = "testdata/testdata.Rdata")
# load("testdata/testdata.Rdata")

## Rename follow-up ID variable
names(fu_df) <- str_replace(names(fu_df), "^gq\\_study\\_id$", "id")

## Remove test patients from each database
inhosp_df <- inhosp_df[grep("test", tolower(inhosp_df$id), invert = TRUE),]
exc_df <- exc_df[grep("test", tolower(exc_df$exc_id), invert = TRUE),]
fu_df <- fu_df[grep("test", tolower(fu_df$id), invert = TRUE),]

## Data management prep: Create POSIXct versions of most relevant date/times
dtvars <- c("enroll_dttm", "death_dttm", "hospdis_dttm")
datevars <- c("daily_date")

inhosp_df <- inhosp_df %>%
  mutate_at(dtvars, "ymd_hm") %>%
  mutate_at(dtvars, funs(date = "as_date")) %>%
  rename_at(dtvars, ~ gsub("tm$", "", .)) %>%
  rename_at(paste0(dtvars, "_date"), ~ gsub("_dttm", "", ., fixed = TRUE)) %>%
  mutate(studywd_date = ymd(studywd_dttm)) %>%
  mutate_at(datevars, ymd) %>%
  select(-studywd_dttm)

################################################################################
## Screening and Exclusions
################################################################################

## -- Barchart for screening and enrollment by month ---------------------------
## We want to plot the number of patients screened, approached, and enrolled by
## month. Need a list of all unique IDs (exclusions + enrolled).

## Screened: Everyone recorded
## Approached: Enrolled + refusals
## Refused: exclusion #11 checked
##      (Inability to obtain informed consent: Patient and/or surrogate refusal)
## Enrolled: Included in in-hospital database

## Get list of any patients with no exclusion date entered, then remove them
exc_id_nodate <- exc_df %>%
  filter(is.na(exc_date)) %>%
  pull(exc_id)

exc_combine <- exc_df %>%
  filter(!is.na(exc_date)) %>%
  separate(exc_date, into = c("year", "month", "day"), sep = "-") %>%
  mutate(Screened = TRUE,
         Approached = !is.na(exc_rsn_11),
         Refused = !is.na(exc_rsn_11),
         Enrolled = FALSE) %>%
  rename(id = exc_id) %>%
  dplyr::select(id, year, month, Screened, Approached, Refused, Enrolled)

inhosp_combine <- inhosp_df %>%
  filter(redcap_event_name == 'Enrollment /Study Day 1') %>%
  separate(enroll_dt, into = c("year", "month", "day", "time"), sep = "-| ") %>%
  mutate(Screened = TRUE,
         Approached = TRUE,
         Refused = FALSE,
         Enrolled = TRUE) %>%
  dplyr::select(id, year, month, Screened, Approached, Refused, Enrolled)

screening_combine <- bind_rows(exc_combine, inhosp_combine) %>%
  mutate(mabb = month.abb[as.numeric(month)],
         myear = paste(year, month, sep = "-"),
         myear_char = ifelse(mabb == "Mar", paste(mabb, year), mabb))

screening_summary <- screening_combine %>%
  group_by(myear, myear_char) %>%
  summarise_at(c("Screened", "Approached", "Refused", "Enrolled"), sum) %>%
  arrange(myear)

## How many patients have been enrolled so far? What is our enrollment goal?
n_screened <- sum(screening_combine$Screened)
pct_approached <- mean(screening_combine$Approached)
pct_excluded <- 1 - pct_approached
pct_refused <- mean(subset(screening_combine, Approached)$Refused)
n_enrolled <- sum(screening_combine$Enrolled)
pct_enrolled <- mean(subset(screening_combine, Approached)$Enrolled)
n_goal <- 900

## Case mix: How many enrolled patients had...
## - Blunt trauma
## - Penetrating trauma
## - Burn
## - TBI
n_blunt <- sum(inhosp_df$trauma_blunt_enr == "Yes", na.rm = TRUE)
pct_blunt <- scales::percent(
  mean(inhosp_df$trauma_blunt_enr == "Yes", na.rm = TRUE)
)
n_pene <- sum(inhosp_df$trauma_penetrate_enr == "Yes", na.rm = TRUE)
pct_pene <- scales::percent(
  mean(inhosp_df$trauma_penetrate_enr == "Yes", na.rm = TRUE)
)
n_burn <- sum(inhosp_df$burn_enr == "Yes", na.rm = TRUE)
pct_burn <- scales::percent(
  mean(inhosp_df$burn_enr == "Yes", na.rm = TRUE)
)
n_tbi <- sum(inhosp_df$tbi_enr == "Yes", na.rm = TRUE)
pct_tbi <- scales::percent(
  mean(inhosp_df$tbi_enr == "Yes", na.rm = TRUE)
)

## -- Line chart for exclusion percentages over time ---------------------------
## Create long-format data set of all exclusions, one row each
exc_df_long <- exc_df %>%
  gather(key = exc_reason, value = was_excluded, exc_rsn_2:exc_rsn_99) %>%
  separate(exc_date, into = c("year", "month", "day"), sep = "-") %>%
  mutate(
    was_excluded = !is.na(was_excluded),
    mabb = month.abb[as.numeric(month)],
    myear = paste(year, month, sep = "-"),
    myear_char = ifelse(mabb == "Nov", paste(mabb, year), mabb),
    Reason = case_when(
      exc_reason == "exc_rsn_2"  ~ "Severe cognitive/neuro disorder",
      exc_reason == "exc_rsn_3"  ~ "Co-enrollment forbidden",
      exc_reason == "exc_rsn_4"  ~ "Substance abuse, psych disorder",
      exc_reason == "exc_rsn_5"  ~ "Blind, deaf, English",
      exc_reason == "exc_rsn_6"  ~ "Death within 24h/hospice",
      exc_reason == "exc_rsn_7"  ~ "Prisoner",
      exc_reason == "exc_rsn_8"  ~ "Lives >200 miles from VUMC",
      exc_reason == "exc_rsn_9"  ~ "Homeless",
      exc_reason == "exc_rsn_10" ~ "Attending refusal",
      exc_reason == "exc_rsn_11" ~ "Patient/surrogate refusal",
      exc_reason == "exc_rsn_12" ~ "No surrogate within 72h",
      exc_reason == "exc_rsn_13" ~ ">72h eligibility prior to screening",
      exc_reason == "exc_rsn_14" ~ "Research leadership refusal",
      exc_reason == "exc_rsn_99" ~ "Other",
      TRUE ~ as.character(NA)
    )
  ) %>%
  filter(was_excluded)

## Data set for exclusions over time: Proportion of each exclusion each month
## How many exclusions total per month?
exc_per_month <- exc_df_long %>%
  dplyr::select(exc_id, myear, was_excluded) %>%
  unique() %>%
  group_by(myear) %>%
  summarise(n_all_exclusions = sum(was_excluded))

exc_over_time <- exc_df_long %>%
  group_by(myear, myear_char, Reason) %>%
  summarise(n_this_exclusion = sum(was_excluded)) %>%
  left_join(exc_per_month, by = "myear") %>%
  mutate(Percent = round((n_this_exclusion / n_all_exclusions)*100)) %>%
  ungroup() %>%
  arrange(myear)

## -- Treemap for cumulative exclusions ----------------------------------------
exc_cumul <- exc_df_long %>%
  group_by(Reason) %>%
  summarise(n_reason = n()) %>%
  mutate(n_patients_exc = nrow(exc_df),
         reason_type = case_when(
           .$Reason %in% c(
             "Severe cognitive/neuro disorder",
             "Substance abuse, psych disorder",
             "Blind, deaf, English",
             "Prisoner", "Homeless"
            ) ~ "Patient characteristics",
           .$Reason %in% c(
             "Attending refusal",
             "Patient/surrogate refusal",
             "Research leadership refusal",
             "No surrogate within 72h",
             ">72h eligibility prior to screening",
             "Co-enrollment forbidden"
           ) ~ "Informed consent/research",
           TRUE ~ "Other exclusions"
         ))

################################################################################
## Phase I (In-Hospital)
################################################################################

## -- Currently: died/withdrew in hospital, discharged, still in hospital ------
## Get IDs for anyone with no enrollment date entered
enroll_id_nodate <- inhosp_df %>%
  filter(redcap_event_name == "Enrollment /Study Day 1", is.na(enroll_date)) %>%
  pull(id)

all_enrolled <- inhosp_df %>%
  ## Restrict to patients with an enrollment date entered
  filter(
    redcap_event_name == "Enrollment /Study Day 1", !is.na(enroll_date)
  ) %>%
  mutate(
    inhosp_status = factor(
      case_when(
        !is.na(hospdis_date) ~ 1,
        !is.na(death_date)   ~ 2,
        !is.na(studywd_date) ~ 3,
        TRUE                 ~ 4
      ),
      levels = 1:4,
      labels = c("Discharged alive", "Died in hospital",
                 "Withdrew in hospital", "Still in hospital")
    )
  )

status_count <- all_enrolled %>%
  group_by(inhosp_status) %>%
  summarise(n_status = n())

## -- Completion of pre-hospital surrogate, caregiver batteries ----------------
## Surrogate battery: General questions, basic/IADLs, NIDA, life space,
##   employment questionnaire, income, grit, BDI (*not* attitude toward donation)
## Caregiver battery: Zarit, memory/behavior checklist
## "Complete" = every section fully or partially completed
surrogate_compvars <- c(
  paste0(
    c("gq", "adl", "nida", "ls", "emp", "income", "grit", "bdi", "iqcode"),
    "_comp_ph"
  )
)
caregiver_compvars <- c(
  paste0(c("zarit", "memory"), "_comp_ph")
)

all_enrolled <- all_enrolled %>%
  mutate_at(
    vars(one_of(c(surrogate_compvars, caregiver_compvars))),
    funs(!is.na(.) & str_detect(., "^Yes"))
  ) %>%
  mutate(
    ph_surrogate_comp =
      rowSums(.[, surrogate_compvars]) == length(surrogate_compvars),
    ph_caregiver_comp =
      rowSums(.[, caregiver_compvars]) == length(caregiver_compvars)
  )

## -- Attitude toward brain donation -------------------------------------------
## This is asked separately of surrogates (during pre-hospital battery) and
## patients (at some point during hospitalization or follow-up, whenever patient
## is cognitively able to answer).
## Same denominator for both: All patients, except those withdrawn by staff due
##  to high IQCODE. (This means rates will be low for patients in particular,
##  since some patients will not have "woken up enough" to be asked; however,
##  there's no straightforward way to remove these patients from the
##  denominator.)

all_enrolled <- all_enrolled %>%
  mutate(
    elig_attitude =
      !(!is.na(studywd_who) &
          studywd_who == "Study staff b/c patient scored IQCODE>3.8"),
    ## Eligible for caregiver assessment: not withdrawn d/t IQCODE *and*
    ##  Zarit not marked with "no [caregiver] available" (some patients don't
    ##  have anyone that meets that definition)
    elig_cg =
      elig_attitude &
      !(!is.na(zarit_comp_ph_rsn) &
          zarit_comp_ph_rsn == "No one available that meets the caregiver definition"),
    attitude_surr = ifelse(
      !elig_attitude, NA, !is.na(attitude_comp_sur) & attitude_comp_sur == "Yes"
    ),
    attitude_pt_inhosp = ifelse(
      !elig_attitude, NA, !is.na(attitude_comp_pt) & attitude_comp_pt == "Yes"
    ),
    attitude_pt_fu = ifelse(
      !elig_attitude, NA,
      !is.na(attitude_comp_fu_pt) & attitude_comp_fu_pt == "Yes"
    ),
    attitude_pt_ever = ifelse(
      !elig_attitude, NA, attitude_pt_inhosp | attitude_pt_fu
    ),
    attitude_pt_cogunable = ifelse(
      !elig_attitude, NA,
      !attitude_pt_ever &
        ((!is.na(attitude_rsn_pt) &
          attitude_rsn_pt == "Patient never cognitively able by hospital discharge") |
        (!is.na(attitude_rsn_fu_pt) &
          attitude_rsn_fu_pt == "Patient never cognitively able"))
    ),
    attitude_pt_died = ifelse(
      !elig_attitude, NA,
      !attitude_pt_ever &
       ((!is.na(attitude_rsn_pt) &
          attitude_rsn_pt == "Patient died or withdrew prior to completing") |
         (!is.na(attitude_rsn_fu_pt) &
            attitude_rsn_fu_pt == "Patient died or withdrew prior to completing"))
    ),
    attitude_pt_missed = ifelse(
      !elig_attitude, NA,
      !(attitude_pt_ever | attitude_pt_cogunable | attitude_pt_died)
    ),
    attitude_pt_status = case_when(
      attitude_pt_inhosp    ~ "Yes, in hospital",
      attitude_pt_fu        ~ "Yes, during follow-up",
      attitude_pt_died      ~ "No, died/withdrew",
      attitude_pt_cogunable ~ "Never cognitively able",
      attitude_pt_missed    ~ "No, missed",
      !elig_attitude        ~ as.character(NA),
      TRUE                  ~ "Fix this"
    )
  )

# attitude_pctcomp <- all_enrolled %>%
#   ## filter(...) %>%
#   dplyr::select(attitude_surr, attitude_pt_ever) %>%
#   ## Get proportion complete for each assessment
#   summarise_all(mean, na.rm = TRUE) %>%
#   ## Reshape to work with plot_asmts_comp()
#   gather(key = asmt_type, value = prop_comp) %>%
#   mutate(
#     ## Clearer battery names
#     asmt_type = case_when(
#       asmt_type == "attitude_surr" ~ "Surrogate",
#       TRUE                         ~ "Patient"
#     ),
#     asmt_type = fct_relevel(asmt_type, "Surrogate", "Patient"),
#     htext = paste0(asmt_type, ": ", scales::percent(prop_comp)),
#     comp_ok = case_when(
#       prop_comp > 0.90 ~ "Excellent",
#       prop_comp > 0.80 ~ "Okay",
#       TRUE             ~ "Uh-oh"
#     )
#   )

## df for patients who *should have* had surrogate batteries completed
##  (currently, all patients *not* withdrawn due to high IQCODE; more criteria
##  may be added)
surrogate_pctcomp <- all_enrolled %>%
  filter(elig_attitude) %>%
  dplyr::select(
    one_of(surrogate_compvars),
    # one_of(caregiver_compvars),
    attitude_pt_ever, attitude_surr
  ) %>%
  ## Get proportion complete for each assessment
  summarise_all(mean, na.rm = TRUE)

## df for patients who *should have* had Zarit + memory/behavior completed
##  (currently, all patients *not* withdrawn due to high IQCODE AND not marked
##  as "no caregiver available")
cg_pctcomp <- all_enrolled %>%
  filter(elig_cg) %>%
  dplyr::select(one_of(caregiver_compvars)) %>%
  ## Get proportion complete for each assessment
  summarise_all(mean, na.rm = TRUE)

## Combine into one dataset for plot
surrogate_pctcomp <- bind_cols(surrogate_pctcomp, cg_pctcomp) %>%
  ## Reshape to work with plot_asmts_comp()
  gather(key = asmt_type, value = prop_comp) %>%
  ## Sort in descending order of % completed
  arrange(str_detect(asmt_type, "^attitude"), desc(prop_comp)) %>%
  mutate(
    x_sorted = 1:n(),
    ## Clearer battery names
    asmt_type = case_when(
      asmt_type == "memory_comp_ph"    ~ "M/B",
      asmt_type == "gq_comp_ph"        ~ "Gen.",
      asmt_type == "emp_comp_ph"       ~ "Emp.",
      asmt_type == "zarit_comp_ph"     ~ "Zarit",
      asmt_type == "grit_comp_ph"      ~ "Grit",
      asmt_type == "income_comp_ph"    ~ "Income",
      asmt_type == "attitude_pt_ever"  ~ "Att., Pt",
      asmt_type == "attitude_surr"     ~ "Att., Surr",
      TRUE ~ toupper(str_remove(asmt_type, "\\_comp\\_ph|sur$"))
    ),
    asmt_type = fct_reorder(asmt_type, x_sorted),
    htext = paste0(asmt_type, ": ", scales::percent(prop_comp)),
    comp_ok = case_when(
      prop_comp > 0.90 ~ "Excellent",
      prop_comp > 0.80 ~ "Okay",
      TRUE             ~ "Uh-oh"
    )
  )

## -- Specimen log: compliance = >0 tubes drawn on days 1, 3, 5, discharge -----
## Get "proper" study *dates* for each ID
study_dates <- tibble(
  study_date =
    map(pull(all_enrolled, enroll_date), ~ seq(., by = 1, length.out = 30)) %>%
    flatten_int() %>%
    as.Date(origin = "1970-1-1")
)

## Create "dummy" data frame with ID, study event, study day, study date up to
## day 30 for each patient
timeline_df <- tibble(
  id = rep(sort(unique(all_enrolled$id)), each = 30),
  study_day = rep(1:30, length(unique(all_enrolled$id)))
) %>%
  left_join(subset(all_enrolled,
                   select = c(id, enroll_date, death_date, hospdis_date,
                              studywd_date)),
            by = "id") %>%
  bind_cols(study_dates) %>%
  ## Add "status" for each day:
  ##  - deceased
  ##  - discharged
  ##  - withdrawn
  ##  - in hospital
  ## With additional indicator for "transition day", or days on which patients
  ## died, were discharged, or withdrew. These days may or may not have data
  ## collected (eg, if patient died in evening, data may have been collected,
  ## but if patient died in morning, likely that no data was collected).
  mutate(
    redcap_event_name = case_when(
      study_day == 1  ~ "Enrollment /Study Day 1",
      TRUE            ~ paste("Study Day", study_day)
    ),
    transition_day = (!is.na(death_date) & study_date == death_date) |
      (!is.na(studywd_date) & study_date == studywd_date) |
      (!is.na(hospdis_date) & study_date == hospdis_date),
    study_status = factor(
      case_when(
        !is.na(death_date) & study_date >= death_date ~ 4,
        !is.na(hospdis_date) & study_date >= hospdis_date ~ 3,
        !is.na(studywd_date) & study_date >= studywd_date ~ 2,
        TRUE ~ 1
      ),
      levels = 1:4,
      labels = c("In hospital", "Withdrawn", "Discharged", "Deceased"))
  )

## Specimen collection: all colors (blue, purple, green, red) done on day 1 and
##  discharge; red *not* done on day 3/5 (all others are)
specimen_df <- inhosp_df %>%
  dplyr::select(
    id, redcap_event_name, specimen_date, starts_with("study_day_specimen"),
    ends_with("microtubes")
  ) %>%
  ## Create a single value for which specimen was drawn (days 1/3/5/discharge)
  unite(specimen_time, starts_with("study_day_specimen"), sep = "; ") %>%
  mutate(
    ## String manipulation so each value includes only "Day x [and Discharge]"
    specimen_time = str_remove_all(specimen_time, "NA|; *"),
    specimen_time = ifelse(
      specimen_time == "", NA,
      str_remove(specimen_time, "Enrollment/| only")
    )
  ) %>%
  separate(
    specimen_time, into = c("specimen_time", "double_duty"), sep = " and "
  ) %>%
  mutate(double_duty = !is.na(double_duty))

## Concatenate records pulling double duty: serve as both day 5 + d/c, eg
specimen_df <- bind_rows(
  specimen_df,
  specimen_df %>%
    filter(double_duty) %>%
    mutate(
      redcap_event_name = "Study Day 30",
      specimen_time = "Discharge"
    )
) %>%
  ## Remove records with no specimen_time
  filter(!is.na(specimen_time)) %>%
  ## Join with records from timeline_df representing days which "should" have
  ##  specimens (days 1, 3, 5, discharge)
  right_join(
    timeline_df %>%
      filter(
        redcap_event_name %in% c(
          "Enrollment /Study Day 1", "Study Day 3", "Study Day 5", "Study Day 30"
        )
      ),
    by = c("id", "redcap_event_name")
  ) %>%
  ## Keep rows where:
  ## - study day 1, 3, 5 and patient hospitalized; or
  ## - discharge day and patient is not deceased or withdrawn
  ## This should remove rows where specimen log filled out after discharge/death
  ## (eg, VIN-0066 day 5)
  filter(
    (redcap_event_name %in%
       c("Enrollment /Study Day 1", "Study Day 3", "Study Day 5") &
       (study_status == "In hospital" | transition_day)) |
      (redcap_event_name == "Study Day 30" &
         !(study_status %in% c("Deceased", "Withdrawn")))
  ) %>%
  ## Reshape to long format, with one record per day/tube color
  dplyr::select(id, redcap_event_name, ends_with("microtubes")) %>%
  gather(key = Color, value = drawn, ends_with("microtubes")) %>%
  mutate(
    Color = str_remove(Color, "\\_microtubes"),
    ## Compliance: At least one tube drawn
    compliant = !is.na(drawn) & drawn > 0,
    ## Factor version of event; rely on redcap_event_name, in case no data was
    ##  entered for specimens
    redcap_event_name = ifelse(
      redcap_event_name == "Study Day 30", "Discharge", redcap_event_name
    ),
    Day = fct_relevel(
      str_remove(redcap_event_name, "[Enrollment /]*Study | Day$"),
      "Day 1", "Day 3", "Day 5", "Discharge"
    )
  ) %>%
  ## Red tubes are not drawn on days 3/5 (unless it was also discharge day)
  filter(!(Color == "red" & Day %in% c("Day 3", "Day 5"))) %>%
  ## Summarize % compliance by study day, tube color
  group_by(Day, Color) %>%
  summarise(
    Compliance = mean(compliant, na.rm = TRUE)
  ) %>%
  ungroup()

################################################################################
## Follow-Up Phase
################################################################################

## Note: We're not dealing with phone-only time points; see MOSAIC dashboard
##  code later if that's needed

## **Patient** assessments at 3, 12m:
## general questions; basic/IADLs; RBANS/CLOX/Trails; employment/income;
##  driving; hospital/ED use; SPPB; handgrip; EQ5D; GOSE; NIDA; AUDIT; BPI; BDI;
##  PCL-5; CD-RISC; social vulnerability
## **Caregiver** assessments at 3, 12m:
## general/employment; Zarit/ memory/behavior; driving

## -- Create dummy df: One record per enrolled patient per f/u time point ------
fu_dummy <- cross_df(
  list(
    id = unique(all_enrolled$id),
    redcap_event_name = unique(fu_df$redcap_event_name)
  )
)

## List of assessments done at each time point
asmts_pt <- c(
  "gq", "biadl", "cog", "emp", "driving", "hus", "sppb", "hand", "eq5d", "gose",
  "nida", "audit", "bpi", "bdi", "pcl", "cd", "social"
)
asmts_cg <- c("cg", "zarit", "mb", "driving_care")

asmts_all <- unique(c(asmts_pt, asmts_cg))
asmts_withdate <- str_replace(asmts_all, "^cd$", "cdrisc")
  ## CD-RISC has inconsistent field names

## -- Function to turn missing assessment indicators to FALSE ------------------
## This happens if (eg) the patient has not yet been reached for an assessment
##  at a given time point; the "test_complete" variable has not yet been filled
##  out, but for monitoring purposes, patient should be counted as not assessed
turn_na_false <- function(x, df){
  ifelse(is.na(x) & df$fu_elig, FALSE, x)
}

## -- Combine in-hospital dates with follow-up data ----------------------------
fu_df2 <- fu_dummy %>%
  ## Only want to monitor 3, 12m assessments
  filter(redcap_event_name %in% paste(c(3, 12), "Month Assessment")) %>%
  ## Merge in-hospital info onto dummy records
  left_join(
    all_enrolled %>%
      select(id, hospdis_date, studywd_date, death_date, inhosp_status),
    by = "id"
  ) %>%
  left_join(
    fu_df %>%
      ## Select only variables needed for status, completion at time point
      dplyr::select(
        id, redcap_event_name, gq_rsn,
        paste0(asmts_all, "_comp"),
        paste0(asmts_withdate, "_date")
      ),
    by = c("id", "redcap_event_name")
  ) %>%
  ## Convert dates to Date
  mutate_at(paste0(asmts_withdate, "_date"), ymd) %>%
  ## Was each assessment completed at this time point?
  mutate_at(paste0(asmts_all, "_comp"), ~ str_detect(., "^Yes")) %>%
  mutate(
    ## How many [patient, caregiver] assessments were done at each?
    n_asmts_pt = rowSums(.[, paste0(asmts_pt, "_comp")], na.rm = TRUE),
    n_asmts_cg = rowSums(.[, paste0(asmts_cg, "_comp")], na.rm = TRUE),
    any_pt = n_asmts_pt > 0,
    any_cg = n_asmts_cg > 0,
    all_pt = n_asmts_pt == length(asmts_pt),
    all_cg = n_asmts_cg == length(asmts_cg)
  )

## -- Figure out patient's status at each time point ---------------------------
## Get first, last asssessment at each time point (these will often, but not
##  always, be the same; sometimes the assessment was broken up into 2+ calls or
##  visits due to time/fatigue)
asmt_minmax <- fu_df2 %>%
  dplyr::select(id, redcap_event_name, paste0(asmts_withdate, "_date")) %>%
  gather(key = "asmt_type", value = "asmt_date", ends_with("_date")) %>%
  ## What is the earliest, latest followup date at this assessment?
  group_by(id, redcap_event_name) %>%
  summarise(
    ## Necessary to redo ymd(); otherwise it thinks none of them are NA?
    first_asmt = ymd(min(asmt_date, na.rm = TRUE)),
    last_asmt = ymd(max(asmt_date, na.rm = TRUE))
  ) %>%
  ungroup()

fu_long <- fu_df2 %>%
  left_join(asmt_minmax, by = c("id", "redcap_event_name")) %>%
  ## Don't need dates anymore
  dplyr::select(-one_of(paste0(asmts_withdate, "_date"))) %>%
  ## Determine status at each time point
  mutate(
    fu_month = as.numeric(str_extract(redcap_event_name, "^\\d+(?= )")),
    daysto_window = case_when(
      fu_month == 1  ~ 30,
      fu_month == 2  ~ 60,
      fu_month == 3  ~ 83,
      fu_month == 6  ~ 180,
      fu_month == 12 ~ 335,
      TRUE           ~ as.numeric(NA)
    ),
    enter_window = as.Date(hospdis_date + daysto_window),
    exit_window = as.Date(
      case_when(
        fu_month %in% c(1, 2) ~ enter_window + 14,
        fu_month == 3         ~ enter_window + 56,
        fu_month == 6         ~ enter_window + 30,
        fu_month == 12        ~ enter_window + 90,
        TRUE                  ~ as.Date(NA)
      )
    ),
    in_window = ifelse(is.na(hospdis_date), NA, enter_window <= Sys.Date()),

    ## Indicator for whether patient refused assessment (but didn't withdraw)
    ## Currently relies on general questions only; per JV, this is an accurate
    ## representation of whether the patient refused the entire assessment
    refused_gq = !is.na(gq_rsn) & gq_rsn == "Patient refusal",

    ## Followup status:
    ## - Had >1 assessment: Assessed
    ## - Died prior to end of followup window: Died
    ## - Withdrew prior to end of followup window: Withdrew
    ## - Not yet in the follow-up window: Currently ineligible
    ## - VMO-001-7: consent did not include phone assessments (1, 2, 6m)
    ## - None of the above: Currently lost to follow-up
    fu_status_pt = factor(
      case_when(
        any_pt                                              ~ 1,
        !is.na(death_date) &
          (inhosp_status == "Died in hospital" |
             death_date < exit_window)                      ~ 2,
        !is.na(studywd_date) &
          (inhosp_status == "Withdrew in hospital" |
             studywd_date < exit_window)                    ~ 3,
        Sys.Date() < enter_window                           ~ 4,
        inhosp_status == "Still in hospital"                ~ as.numeric(NA),
        refused_gq                                          ~ 5,
        TRUE                                                ~ 6
      ),
      levels = 1:6,
      labels = c(
        "Assessment fully or partially completed",
        "Died before follow-up window ended",
        "Withdrew before follow-up window ended",
        "Not yet eligible for follow-up",
        "Refused assessment (but did not withdraw)",
        "Eligible, but not yet assessed"
      )
    ),

    fu_status_cg = factor(
      case_when(
        any_cg                                              ~ 1,
        !is.na(death_date) &
          (inhosp_status == "Died in hospital" |
             death_date < exit_window)                      ~ 2,
        !is.na(studywd_date) &
          (inhosp_status == "Withdrew in hospital" |
             studywd_date < exit_window)                    ~ 3,
        Sys.Date() < enter_window                           ~ 4,
        inhosp_status == "Still in hospital"                ~ as.numeric(NA),
        refused_gq                                          ~ 5,
        TRUE                                                ~ 6
      ),
      levels = 1:6,
      labels = c(
        "Assessment fully or partially completed",
        "Died before follow-up window ended",
        "Withdrew before follow-up window ended",
        "Not yet eligible for follow-up",
        "Refused assessment (but did not withdraw)",
        "Eligible, but not yet assessed"
      )
    ),

    ## Indicators for whether patient/caregiver is eligible for followup
    ##  (included in denominator) and has been assessed (included in numerator)
    fu_elig_pt = fu_status_pt %in% c(
      "Assessment fully or partially completed",
      "Refused assessment (but did not withdraw)",
      "Eligible, but not yet assessed"
    ),
    fu_comp_pt = ifelse(
      !fu_elig_pt, NA, fu_status_pt == "Assessment fully or partially completed"
    ),
    fu_elig_cg = fu_status_cg %in% c(
      "Assessment fully or partially completed",
      "Refused assessment (but did not withdraw)",
      "Eligible, but not yet assessed"
    ),
    fu_comp_cg = ifelse(
      !fu_elig_cg, NA, fu_status_pt == "Assessment fully or partially completed"
    )
  ) %>%
  ## Set asmt indicators to FALSE if pt eligible but no data yet entered
  ## Patient
  mutate_at(
    vars(paste0(asmts_pt, "_comp")),
    funs(ifelse(is.na(.) & fu_elig_pt, FALSE, .))
  ) %>%
  ## Caregiver
  mutate_at(
    vars(paste0(asmts_cg, "_comp")),
    funs(ifelse(is.na(.) & fu_elig_cg, FALSE, .))
  )

# ## -- Check patients without followup ----------------------------------------
# fu_long %>%
#   filter(fu_status_pt == "Eligible, but not yet assessed") %>%
#   dplyr::select(
#     id, redcap_event_name, hospdis_date, enter_window, exit_window
#   ) %>%
#   arrange(redcap_event_name) %>%
#   write_csv(path = "testdata/eligible_nofu.csv", na = "", col_names = TRUE)

## -- Summary statistics for dashboard -----------------------------------------
## Overall % complete at each time point
fu_totals <- fu_long %>%
  dplyr::select(
    redcap_event_name, starts_with("fu_elig"), starts_with("fu_comp")
  ) %>%
  group_by(redcap_event_name) %>%
  summarise(
    n_elig_pt = sum(fu_elig_pt),
    n_comp_pt = sum(fu_comp_pt, na.rm = TRUE),
    prop_comp_pt = mean(fu_comp_pt, na.rm = TRUE),
    n_elig_cg = sum(fu_elig_cg),
    n_comp_cg = sum(fu_comp_cg, na.rm = TRUE),
    prop_comp_cg = mean(fu_comp_cg, na.rm = TRUE)
  )

fu_asmts <- fu_long %>%
  dplyr::select(
    redcap_event_name, starts_with("fu_comp"), ends_with("_comp")
  ) %>%
  gather(key = asmt_type, value = asmt_done, ends_with("_comp")) %>%
  ## Was overall patient/caregiver followup completed? Which variable depends
  ##  on which assessment we're talking about
  mutate(
    fu_comp = case_when(
      asmt_type %in% paste0(asmts_pt, "_comp") ~ fu_comp_pt,
      TRUE                                     ~ fu_comp_cg
    )
  ) %>%
  ## Only look at % of individual assessments done when overall assessment was
  ##  attempted
  filter(fu_comp) %>%
  group_by(redcap_event_name, asmt_type) %>%
  summarise(
    n_elig = sum(fu_comp, na.rm = TRUE),
      ## "eligible" here means overall assessment fully or partially done
    n_comp = sum(asmt_done, na.rm = TRUE),
      ## "completed" here means individual assessment completed
    prop_comp = mean(asmt_done, na.rm = TRUE)
  )

# ## -- Rearrange data for Sankey plot -------------------------------------------
# ## source = enrollment; target = end of hospitalization
# sankey_hospital <- all_enrolled %>%
#   dplyr::select(id, inhosp_status) %>%
#   distinct() %>%
#   set_names(c("id", "target")) %>%
#   mutate(
#     source = "Enrolled",
#     target = case_when(
#       target == "Still in hospital" ~ "Hospitalized",
#       target == "Discharged alive" ~ "Discharged",
#       TRUE ~ stringr::str_replace(target, " in ", ", ")
#     )
#   )
#
# ## source = status after illness; target = status at 3m
# sankey_3m <- fu_long %>%
#   filter(
#     redcap_event_name == "3 Month Assessment",
#     inhosp_status != "Still in hospital"
#   ) %>%
#   dplyr::select(id, inhosp_status, fu_status) %>%
#   set_names(c("id", "source", "target")) %>%
#   mutate(
#     source = case_when(
#       source == "Died in hospital"     ~ "Died, hospital",
#       source == "Withdrew in hospital" ~ "Withdrew, hospital",
#       source == "Still in hospital"    ~ "Hospitalized",
#       TRUE                             ~ "Discharged"
#     ),
#     target = case_when(
#       source == "Died, hospital" |
#         target == "Died before follow-up window ended" ~ "Died, 3m",
#       source == "Withdrew, hospital" |
#         target == "Withdrew before follow-up window ended" ~ "Withdrew, 3m",
#       source == "Hospitalized" ~ "Hospitalized",
#       target == "Assessment fully or partially completed" ~ "Assessed, 3m",
#       target %in% c(
#         "Eligible, but not yet assessed",
#         "Refused assessment (but did not withdraw)"
#       ) ~ "Not assessed, 3m",
#       target == "Not yet eligible for follow-up" ~ "Not yet eligible, 3m",
#       TRUE ~ "Missing"
#     )
#   )
#
# ## source = status at 3m; target = status at 12m
# sankey_12m <- fu_long %>%
#   filter(
#     redcap_event_name == "12 Month Assessment",
#     inhosp_status != "Still in hospital"
#   ) %>%
#   dplyr::select(id, fu_status) %>%
#   left_join(dplyr::select(sankey_3m, id, target)) %>%
#   ## target at 3m is now source at 12m
#   set_names(c("id", "target", "source")) %>%
#   mutate(
#     target = case_when(
#       source == "Hospitalized" ~ "Hospitalized",
#       target == "Died before follow-up window ended" ~ "Died, 12m",
#       target == "Withdrew before follow-up window ended" ~ "Withdrew, 12m",
#       target == "Assessment fully or partially completed" ~ "Assessed, 12m",
#       target %in% c(
#         "Eligible, but not yet assessed",
#         "Refused assessment (but did not withdraw)"
#       ) ~ "Not assessed, 12m",
#       target == "Not yet eligible for follow-up" ~ "Not yet eligible, 12m",
#       TRUE ~ "Missing"
#     )
#   )
#
# ## Calculate final weights for each edge (# patients with each source/target combo)
# sankey_edges <- bind_rows(sankey_hospital, sankey_3m, sankey_12m) %>%
#   dplyr::select(-id) %>%
#   group_by(source, target) %>%
#   summarise(weight = n()) %>%
#   ungroup()
