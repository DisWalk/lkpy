import logging

import pandas as pd
import numpy as np

from pytest import mark

try:
    import implicit
    have_implicit = True
except ImportError:
    have_implicit = False

import lk_test_utils as lktu
from lenskit.algorithms.implicit import ALS, BPR

_log = logging.getLogger(__name__)

simple_df = pd.DataFrame({'item': [1, 1, 2, 3],
                          'user': [10, 12, 10, 13],
                          'rating': [4.0, 3.0, 5.0, 2.0]})


@mark.slow
@mark.skipif(not have_implicit, reason='implicit not installed')
def test_implicit_als_train_rec():
    algo = ALS(25)
    ratings = lktu.ml_pandas.renamed.ratings

    model = algo.train(ratings)
    assert model is not None

    recs = algo.recommend(model, 100, n=20)
    assert len(recs) == 20


@mark.slow
@mark.eval
@mark.skipif(not have_implicit, reason='implicit not installed')
@mark.skipif(not lktu.ml100k.available, reason='ML100K data not present')
def test_implicit_als_batch_accuracy():
    import lenskit.crossfold as xf
    from lenskit import batch, topn
    import lenskit.metrics.topn as lm

    ratings = lktu.ml100k.load_ratings()

    algo = ALS(25)

    def eval(train, test):
        _log.info('running training')
        train['rating'] = train.rating.astype(np.float_)
        model = algo.train(train)
        users = test.user.unique()
        _log.info('testing %d users', len(users))
        candidates = topn.UnratedCandidates(train)
        recs = batch.recommend(algo, model, users, 100, candidates, test)
        return recs

    folds = xf.partition_users(ratings, 5, xf.SampleFrac(0.2))
    recs = pd.concat(eval(train, test) for (train, test) in folds)

    _log.info('analyzing recommendations')
    ndcg = recs.groupby('user').rating.apply(lm.ndcg)
    _log.info('ndcg for users is %.4f', ndcg.mean())
    assert ndcg.mean() > 0


@mark.slow
@mark.skipif(not have_implicit, reason='implicit not installed')
def test_implicit_bpr_train_rec():
    algo = BPR(25)
    ratings = lktu.ml_pandas.renamed.ratings

    model = algo.train(ratings)
    assert model is not None

    recs = algo.recommend(model, 100, n=20)
    assert len(recs) == 20