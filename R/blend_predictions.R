#' Determine stacking coefficients from a data stack
#'
#' @description 
#' Evaluates a data stack by fitting a regularized model on the 
#' assessment predictions from each candidate member to predict 
#' the true outcome.
#' 
#' This process determines the "stacking coefficients" of the model 
#' stack. The stacking coefficients are used to weight the
#' predictions from each candidate (represented by a unique column
#' in the data stack), and are given by the betas of a LASSO model
#' fitting the true outcome with the predictions given in the
#' remaining columns of the data stack.
#' 
#' Candidates with non-zero stacking coefficients are model stack 
#' members, and need to be trained on the full training set (rather
#' than just the assessment set) with `fit_members()`. This function
#' is typically used after a number of calls to `add_candidates()`.
#' 
#' @param data_stack A `data_stack` object
#' @param penalty A numeric vector of proposed penalty values used in member
#'   weighting. Higher penalties will generally result in fewer members 
#'   being included in the resulting model stack, and vice versa. This argument
#'   will be tuned on unless a single penalty value is given.
#' @param non_negative A logical giving whether to restrict stacking 
#'   coefficients to non-negative values. If `TRUE` (default), 0 is passed as 
#'   the `lower.limits` argument to `glmnet::glmnet` in fitting the
#'   model on the data stack. Otherwise, `-Inf`.
#' @param metric A call to `yardstick::metric_set()`. The metric(s) to use in 
#'   tuning the lasso penalty on the stacking coefficients. Default values are
#'   determined by `tune::tune_grid` from the outcome class.
#' @param control An object inheriting from `control_grid` to be passed to
#'   the model determining stacking coefficients. See `tune::control_grid`
#'   documentation for details on possible values. Note that any `extract`
#'   entry will be overwritten internally.
#' @param verbose A logical for logging results as they are generated. Despite 
#'   this argument, warnings and errors are always shown.
#' @param use_candidate_resampling A logical for using the same resampling for 
#'   blending predictions as for candidate models.
#' @param regression_type A string indicating wether to use `lasso` or `ridge` 
#'   regression
#' @inheritParams add_candidates
#' 
#' @return A `model_stack` object—while `model_stack`s largely contain the
#' same elements as `data_stack`s, the primary data objects shift from the
#' assessment set predictions to the member models.
#' 
#' @template note_example_data
#' 
#' @examples 
#' \donttest{
#' # see the "Example Data" section above for
#' # clarification on the objects used in these examples!
#' 
#' # put together a data stack
#' reg_st <- 
#'   stacks() %>%
#'   add_candidates(reg_res_lr) %>%
#'   add_candidates(reg_res_svm) %>%
#'   add_candidates(reg_res_sp)
#'   
#' reg_st
#'
#' # evaluate the data stack
#' reg_st %>%
#'   blend_predictions()
#' 
#' # include fewer models by proposing higher penalties
#' reg_st %>% 
#'   blend_predictions(penalty = c(.5, 1))
#' 
#' # allow for negative stacking coefficients 
#' # with the non_negative argument
#' reg_st %>% 
#'   blend_predictions(non_negative = FALSE)
#'   
#' # use a custom metric in tuning the lasso penalty
#' library(yardstick)
#' reg_st %>% 
#'   blend_predictions(metric = metric_set(rmse))
#'   
#' # pass control options for stack blending
#' reg_st %>% 
#'   blend_predictions(
#'     control = tune::control_grid(allow_par = TRUE)
#'   )
#'   
#' # the process looks the same with 
#' # multinomial classification models
#' class_st <-
#'   stacks() %>%
#'   add_candidates(class_res_nn) %>%
#'   add_candidates(class_res_rf) %>%
#'   blend_predictions()
#'   
#' class_st
#' 
#' # ...or binomial classification models
#' log_st <-
#'   stacks() %>%
#'   add_candidates(log_res_nn) %>%
#'   add_candidates(log_res_rf) %>%
#'   blend_predictions()
#'   
#' log_st
#' }
#' 
#' @family core verbs
#' @export
blend_predictions <- function(data_stack, penalty = 10 ^ (-6:-1), 
                              non_negative = TRUE, metric = NULL,
                              control = tune::control_grid(),
                              verbose = FALSE, use_candidate_resampling = FALSE, 
                              regression_type = "lasso", ...) {
  check_inherits(data_stack, "data_stack")
  check_blend_data_stack(data_stack)
  check_penalty(penalty)
  check_inherits(non_negative, "logical")
  if (!is.null(metric)) {
    check_inherits(metric, "metric_set")
  }
  check_inherits(control, "control_grid")
  check_inherits(verbose, "logical")
  
  outcome <- attr(data_stack, "outcome")
  
  preds_formula <- 
    paste0(outcome, " ~ .") %>%
    as.formula()
  
  lvls <- levels(data_stack[[outcome]])
  
  if(use_candidate_resampling) {
    dat <- tibble::as_tibble(data_stack) %>% na.fail()
    rsmpl <- get_candidate_resampling(data_stack)
    
  } else {
    dat <- tibble::as_tibble(data_stack) %>% na.omit()
    rsmpl <- rsample::bootstraps(dat)
  }
  
  
  ll <- if (non_negative) {0} else {-Inf}
  mixture <- if(regression_type == "lasso") {1} else {0}
  
  if (attr(data_stack, "mode") == "regression") {
    model_spec <- 
      parsnip::linear_reg(penalty = tune::tune(), mixture = mixture) %>%
      parsnip::set_engine("glmnet", lower.limits = ll)
    
    preds_wf <-
      workflows::workflow() %>%
      workflows::add_model(model_spec) %>%
      workflows::add_formula(preds_formula)
  } else {
    # The class probabilities add up to one so we remove the probability columns
    # associated with the first level of the outcome. 
    col_filter <- paste0(".pred_", lvls[1])
    dat <- dat %>% dplyr::select(-dplyr::starts_with(!!col_filter))
    if (length(lvls) == 2) {
      model_spec <-
        parsnip::logistic_reg(penalty = tune::tune(), mixture = mixture) %>% 
        parsnip::set_engine("glmnet", lower.limits = ll) %>% 
        parsnip::set_mode("classification")
    } else {
      model_spec <-
        parsnip::multinom_reg(penalty = tune::tune(), mixture = mixture) %>% 
        parsnip::set_engine("glmnet", lower.limits = ll) %>% 
        parsnip::set_mode("classification")
    }
    
    preds_wf <- 
      workflows::workflow() %>%
      workflows::add_recipe(
        recipes::recipe(
          preds_formula, 
          data = dat
          )
      ) %>%
      workflows::add_model(model_spec)
  }
  
  get_models <- function(x) {
    x %>% 
      workflows::pull_workflow_fit() %>% 
      purrr::pluck("fit")
  }
  
  control$extract <- get_models
  control$save_pred <- TRUE

  candidates <- 
    preds_wf %>%
    tune::tune_grid(
      resamples = rsmpl,
      grid = tibble::tibble(penalty = penalty),
      metrics = metric,
      control = control
    )
  
  metric <- tune::.get_tune_metric_names(candidates)[1]
  best_param <- tune::select_best(candidates, metric = metric)
  coefs <-
    model_spec %>%
    tune::finalize_model(best_param) %>%
    generics::fit(formula = preds_formula, data = dat)

  model_stack <- 
    structure(
      list(model_defs = attr(data_stack, "model_defs"),
           coefs = coefs,
           penalty = list(penalty = best_param$penalty, metric = metric),
           metrics = glmnet_metrics(candidates),
           pred = tune::collect_predictions(candidates, summarize = TRUE, parameters = best_param),
           equations = get_expressions(coefs),
           cols_map = attr(data_stack, "cols_map"),
           model_metrics = attr(data_stack, "model_metrics"),
           train = attr(data_stack, "train"),
           mode = attr(data_stack, "mode"),
           outcome = attr(data_stack, "outcome"),
           data_stack = dat,
           splits = attr(data_stack, "splits")),
      class = c("linear_stack", "model_stack", "list")
    )
  
  if (model_stack_constr(model_stack)) {model_stack}
}

check_penalty <- function(x) {
  if (!is.numeric(x)) {
    glue_stop(
      "The argument to 'penalty' must be a numeric, but the supplied penalty's ",
      "class is `{list(class(x))}`"
    )
  }
  
  if (length(x) == 0) {
    glue_stop("Please supply one or more penalty values.")
  }
  
  if (any(x < 0)) {
    glue_stop("Please supply only nonnegative values to the penalty argument.")
  }
}

# ------------------------------------------------------------------------------

glmnet_metrics <- function(x) {
  res <- tune::collect_metrics(x)
  pens <- sort(unique(res$penalty))
  x$glmnet_fits <- purrr::map(x$.extracts, ~ .x$.extracts[[1]])
  num_mem <- 
    purrr::map_dfr(x$glmnet_fits, num_members, pens) %>% 
    dplyr::group_by(penalty) %>% 
    dplyr::summarize(
      .metric = "num_members",
      .estimator = "Poisson",
      mean = mean(members, na.rm = TRUE), 
      n = sum(!is.na(members)),
      std_err = sqrt(mean/n)
    ) %>% 
    dplyr::ungroup() %>% 
    dplyr::full_join(
      res %>% dplyr::select(penalty, .config) %>% dplyr::distinct(),
      by = "penalty"
    )
  dplyr::bind_rows(res, num_mem)
}

num_members <- function(x, penalties) {
  glmn_coef <-  coef(x, s = penalties)
  if (is.list(glmn_coef)) {
    glmn_coef <- do.call("rbind", glmn_coef)
  }
  glmn_coef <- glmn_coef[rownames(glmn_coef) != "(Intercept)",,drop = FALSE]
  mems <- apply(glmn_coef, 2, function(x) sum(x != 0))
  tibble::tibble(penalty = penalties, members = unname(mems))  
}

# set attributes from new_attr that are not
# already set in x
safe_attr <- function(x, new_attr) {
  res <- x
  
  x_attr <- attributes(x)
  
  dup_attrs <- names(new_attr) %in% names(x_attr)
  
  attributes(res) <- c(x_attr, new_attr[!dup_attrs])
  
  attr(res, "rset_info") <- NULL
  
  res
}

check_blend_data_stack <- function(data_stack) {
  # many possible checks we could do here are redundant with those we
  # carry out in fit_members() -- just check for bare stacks, 1-candidate
  # stacks, and non-stack objects
  if (!inherits(data_stack, "data_stack")) {
    check_inherits(data_stack, "data_stack")
  } else if (ncol(data_stack) == 0) {
      glue_stop(
        "The data stack supplied as the argument to `data_stack` has no ",
        "candidate members. Please first add candidates with ",
        "the `add_candidates()` function."
      )
  } else if ((ncol(data_stack) == 2 && attr(data_stack, "mode") == "regression") || 
             ncol(data_stack) == length(levels(data_stack[[1]])) + 1) {
    glue_stop(
      "The supplied data stack only contains one candidate member. Please ",
      "add more candidate members using `add_candidates()` before blending."
    )
  }
  
  invisible(NULL)
}

get_candidate_resampling <- function(data_stack) {
  dat <- tibble::as_tibble(data_stack)
  rsmpl <- attr(data_stack, "splits") 
  class(rsmpl) <- c(attr(rsmpl, "rset_info")$att$class, "rset", class(rsmpl))
  rsmpl$splits = purrr::map(rsmpl$splits,
                            ~{
                              .x$data <- dat
                              .x
                            })
  
  rsmpl
}

