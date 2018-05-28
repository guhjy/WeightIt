#GBM for continuous treatments using Zhu, Coffman, & Ghosh (2014) code
ps.cont <- function(formula, data, n.trees = 20000, interaction.depth = 4, shrinkage = 0.0005, bag.fraction = 1,
                     print.level = 0, verbose = FALSE, stop.method, use.optimize = 2, sampw = NULL, ...) {

  A <- list(...)
  terms <- match.call()

  F.aac.w <- function(i, data, t, covs, ps.model, ps.num, corr.type, mean.max, z.trans, s.weights) {
    GBM.fitted <- predict(ps.model, newdata = data, n.trees = floor(i),
                          type = "response")
    ps.den <- dnorm((t - GBM.fitted)/sd(t - GBM.fitted), 0, 1)
    wt <- ps.num/ps.den

    if (corr.type == "spearman") corr_ <- apply(covs, 2, wCorr::weightedCorr, y = t, method = "spearman", weights = wt * s.weights)
    else if (corr.type == "pearson") corr_ <- apply(covs, 2, function(c) {
      if (is.factor(c)) wCorr::weightedCorr(c, y = t, method = "polyserial", weights = wt * s.weights)
      else wCorr::weightedCorr(c, y = t, method = "pearson", weights = wt * s.weights)})
    else stop("stop.method is not correctly specified.", call. = FALSE)

    if (z.trans) corr_ <- cor2z(corr_)

    return(mean.max(abs(corr_)))

  }
  cor2z <- function(x) {return(.5 * log((1+x)/(1-x)))}
  desc.wts.cont <- function(t, covs, weights, which.tree) {
    desc <- setNames(vector("list", 10),
                     c("ess", "n", "max.p.cor", "mean.p.cor", "rmse.p.cor", "max.s.cor", "mean.s.cor", "rmse.s.cor", "bal.tab", "n.trees"))
    desc[["bal.tab"]][["results"]] <- data.frame(p.cor = apply(covs, 2, function(c) weightedCorr(t, c, method = "pearson", weights = weights)),
                                p.cor.z = NA,
                                s.cor = apply(covs, 2, function(c) weightedCorr(t, c, method = "spearman", weights = weights)),
                                s.cor.z = NA,
                                row.names = colnames(covs))
    desc[["bal.tab"]][["results"]][["p.cor.z"]] <- cor2z(desc[["bal.tab"]][["results"]][["p.cor"]])
    desc[["bal.tab"]][["results"]][["s.cor.z"]] <- cor2z(desc[["bal.tab"]][["results"]][["s.cor"]])
    desc[["ess"]] <- (sum(weights)^2)/sum(weights^2)
    desc[["n"]] <- length(t)
    desc[["max.p.cor"]] <- max(abs(desc[["bal.tab"]][["results"]][["p.cor"]]))
    desc[["mean.p.cor"]] <- mean(abs(desc[["bal.tab"]][["results"]][["p.cor"]]))
    desc[["rmse.p.cor"]] <- sqrt(mean(desc[["bal.tab"]][["results"]][["p.cor"]]^2))
    desc[["max.s.cor"]] <- max(abs(desc[["bal.tab"]][["results"]][["s.cor"]]))
    desc[["mean.s.cor"]] <- mean(abs(desc[["bal.tab"]][["results"]][["s.cor"]]))
    desc[["rmse.s.cor"]] <- sqrt(mean(desc[["bal.tab"]][["results"]][["s.cor"]]^2))
    desc[["n.trees"]] <- which.tree

    return(desc)
  }

  # Find the optimal number of trees using correlation

  if (missing(stop.method)) {
    warning("No stop.method was entered. Using \"s.mean\", the mean of the absolute Z-tranformed Spearman correlations.", call. = FALSE)
    stop.method <- "s.mean.z"
  }
  else {
    stop.method <- tryCatch(match.arg(tolower(stop.method), apply(expand.grid(c("s", "p"),
                                                                              c(".mean", ".max", ".mse"),
                                                                              c("", ".z")), 1, paste, collapse = ""),
                                      several.ok = TRUE),
                            error = function(e) {
                              warning("The entered stop.method is not one of the accepted values.\nSee ?weightit for the accepted values of stop.method for continuous treatments.\nUsing \"s.mean.z\".",
                                      call. = FALSE, immediate. = TRUE)
                              return("s.mean.z")
                            })
  }

  stop.method.split <- strsplit(stop.method, ".", fixed = TRUE)
  corr.type <- sapply(stop.method.split, function(x) switch(x[1], s = "spearman", p = "pearson", k = "kendall"))
  mean.max <- lapply(stop.method.split, function(x) switch(x[2],
                                                           mean = function(y) mean(abs(y), na.rm = TRUE),
                                                           max = function(y) max(abs(y), na.rm = TRUE),
                                                           mse = function(y) mean(y^2, na.rm = TRUE)))
  z.trans <- sapply(stop.method.split, function(x) length(x) == 3 && x[3] == "z")

  t.c <- get.covs.and.treat.from.formula(formula, data)
  t <- t.c[["treat"]]
  covs <- t.c[["model.covs"]]
  #covs <- apply(covs, 2, function(x) if (is.factor(x) || is.character(x) || !nunique.gt(x, 2)) factor(x))
  new.data <- data.frame(t, t.c[["reported.covs"]])

  if (is_null(sampw)) {
    if (is_not_null(A[["s.weights"]])) s.weights <- A[["s.weights"]]
    else s.weights <- rep(1, length(t))
  }
  else s.weights <- sampw

  #form.num <- update(formula, . ~ 1)
  #model.num <- glm(form.num, data = data.frame(data, s.weights = s.weights), weights = s.weights)

  desc <- setNames(vector("list", 1 + length(stop.method)),
                   c("unw", stop.method))

  desc[["unw"]] <- desc.wts.cont(t, covs, s.weights, NA)

  #model.num <- lm.wfit
  ps.num <- dnorm((t - weighted.mean(t, s.weights))/sqrt(cov.wt(matrix(t, ncol = 1), s.weights)[["cov"]][1,1]), 0 ,1)
  #ps.num <- dnorm((t - model.num$fitted.values)/sqrt(summary(model.num)$dispersion), 0 ,1)
  model.den <- gbm::gbm(formula(new.data), data = new.data, shrinkage = shrinkage,
                        interaction.depth = interaction.depth, distribution = "gaussian", n.trees = n.trees,
                        bag.fraction = bag.fraction,
                        n.minobsinnode = 10, train.fraction = 1, keep.data = FALSE,
                        verbose = FALSE,
                        weights = s.weights)

  if (use.optimize == 1) {
    w <- ps <- setNames(as.data.frame(matrix(0, nrow = nrow(covs), ncol = length(stop.method))), stop.method)
    best.tree <- setNames(numeric(length(stop.method)), stop.method)

    for (s in seq_along(stop.method)) {
      sm <- stop.method[s]

      # get optimal number of iterations
      # Step #1: evaluate at 25 equally spaced points
      iters <- round(seq(1, n.trees, length = 25))
      bal <- rep(0,length(iters))

      for (j in 1:length(iters)) {

        bal[j] <- F.aac.w(iters[j], data = new.data, t = t, covs = covs,
                          ps.model = model.den,
                          ps.num = ps.num, corr.type = corr.type[s], mean.max = mean.max[[s]],
                          z.trans = z.trans[s], s.weights = s.weights)
      }
      # Step #2: find the interval containing the approximate minimum
      interval <- which.min(bal) + c(-1,1)
      interval[1] <- max(1, interval[1])
      interval[2] <- min(length(iters), interval[2])

      # Step #3: refine the minimum by searching with the identified interval

      opt <- optimize(F.aac.w, interval = iters[interval], data = new.data, t = t, covs = covs,
                      ps.model = model.den,
                      ps.num = ps.num, corr.type = corr.type[s], mean.max = mean.max[[s]],
                      z.trans = z.trans[s], s.weights = s.weights, tol = .Machine$double.eps)

      best.tree[s] <- floor(opt$minimum)

      # compute propensity score weights
      GBM.fitted <- predict(model.den, newdata = new.data, n.trees = floor(best.tree[s]),
                            type = "response")
      ps[[s]] <- dnorm((t - GBM.fitted)/sd(t - GBM.fitted), 0, 1)
      w[[s]] <- ps.num/ps[[s]]
    }
  }
  else if (use.optimize == 2) {
    w <- ps <- setNames(as.data.frame(matrix(0, nrow = nrow(covs), ncol = length(stop.method))), stop.method)
    best.tree <- setNames(numeric(length(stop.method)), stop.method)
    for (s in seq_along(stop.method)) {
      opt <- optimize(F.aac.w, interval = c(1, n.trees), data = new.data, t = t, covs = covs,
                      ps.model = model.den,
                      ps.num = ps.num, corr.type = corr.type[s], mean.max = mean.max[[s]],
                      z.trans = z.trans[s], s.weights = s.weights, tol = .Machine$double.eps)
      best.tree[s] <- floor(opt$minimum)

      GBM.fitted <- predict(model.den, newdata = new.data, n.trees = floor(best.tree[s]),
                            type = "response")
      ps[[s]] <- dnorm((t - GBM.fitted)/sd(t - GBM.fitted), 0, 1)
      w[[s]] <- ps.num/ps[[s]]
    }
    bal <- NULL

  }
  else {
    bal <- wt <- ps.den <- vector("list", n.trees)
    for (i in 1:n.trees) {
      # Calculate the inverse probability weights
      model.den$fitted = predict(model.den, newdata = data,
                                 n.trees = floor(i), type = "response")
      ps.den[[i]] = dnorm((t - model.den$fitted)/sd(t - model.den$fitted), 0, 1)
      wt[[i]] <- ps.num/ps.den[[i]]

      bal[[i]] <- setNames(vector('list', length(stop.method)), stop.method)
      for (s in seq_along(stop.method)) {
        if (s > 1 && corr.type[s] %in% corr.type[1:(s-1)]) corr_ <- bal[[i]][corr.type == corr.type[s]][[1]]
        else if (corr.type[s] == "spearman") corr_ <- apply(covs, 2, wCorr::weightedCorr, y = t, method = "spearman", weights = wt[[i]] * s.weights)
        else if (corr.type[s] == "pearson") corr_ <- apply(covs, 2, function(c) {
          if (is.factor(c)) wCorr::weightedCorr(t, y = c, method = "polyserial", weights = wt[[i]] * s.weights)
          else wCorr::weightedCorr(t, y = c, method = "pearson", weights = wt[[i]] * s.weights)})
        else stop("stop.method is not correctly specified.", call. = FALSE)

        bal[[i]][[s]] <- setNames(corr_, colnames(covs))
      }

    }

    w <- ps <- setNames(as.data.frame(matrix(0, nrow = nrow(covs), ncol = length(stop.method))), stop.method)
    best.tree <- setNames(numeric(length(stop.method)), stop.method)
    for (s in seq_along(stop.method)) {
      if (z.trans[s]) {
        best.tree[s] <- floor(which.min(sapply(bal, function(b) mean.max[[s]](cor2z(b[[s]])))))
      }
      else {
        best.tree[s] <- floor(which.min(sapply(bal, function(b) mean.max[[s]](b[[s]]))))
      }
      ps[[s]] <- ps.den[[best.tree[s]]]
      w[[s]] <- wt[[best.tree[s]]]
    }

  }

  if(any(n.trees - best.tree < 100)) warning("Optimal number of iterations is close to the specified n.trees. n.trees is likely set too small and better balance might be obtainable by setting n.trees to be larger.", call. = FALSE)

  for (s in stop.method) {
    desc[[s]] <- desc.wts.cont(t, covs, w[[s]]*s.weights, best.tree[s])
  }

  out <- list(treat = t, desc = desc, ps = ps, w = w,
              sampw = sampw, estimand = NULL, datestamp = date(),
              parameters = terms, alerts = NULL, iters = NULL, balance = NULL,
              n.trees = n.trees, data = data, gbm.obj = model.den)

  class(out) <- c("ps.cont")

  return(out)

}

summary.ps.cont <- function (object, ...) {
  summary.tab <- NULL
  typ <- NULL
  n.tp <- length(object$desc)
  for (i.tp in 1:n.tp) {
    desc.temp <- object$desc[[i.tp]]
    iter <- desc.temp$n.trees
    tp <- names(object$desc)[i.tp]
    summary.tab <- rbind(summary.tab, with(desc.temp, c(n, ess, max.p.cor, mean.p.cor, rmse.p.cor,
                                                        max.s.cor, mean.s.cor, rmse.s.cor, iter)))
    typ <- c(typ, tp)
  }
  summary.tab <- matrix(summary.tab, nrow = n.tp)
  rownames(summary.tab) <- typ
  colnames(summary.tab) <- c("n", "ess", "max.p.cor", "mean.p.cor", "rmse.p.cor",
                             "max.s.cor", "mean.s.cor", "rmse.s.cor", "iter")
  class(summary.tab) <- "summary.ps"
  return(summary.tab)
}