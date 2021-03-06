% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/predict.R
\name{predict.data_stack}
\alias{predict.data_stack}
\title{Predicting with a model stack}
\usage{
\method{predict}{data_stack}(object, ...)
}
\arguments{
\item{object}{A data stack.}

\item{...}{Additional arguments. Currently ignored.}
}
\description{
To predict with a stacked ensemble, the data stack must be evaluated
with \code{blend_predictions()} and its member models fitted with
\code{fit_members()} to predict on new data.
}
